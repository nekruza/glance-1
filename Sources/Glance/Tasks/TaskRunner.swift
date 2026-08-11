import Foundation

/// Execution pipeline (PRD V2 F6/F7, FR43–FR53): plan → plan gate → execute
/// in isolation → review gate → gated boundary actions.
///
/// Isolation & boundary enforcement (FR45, FR49, §6 A8):
///  - `code` tasks run in a fresh `git worktree`; the user's checkout is never
///    touched. Approved runs hand back a branch; push/PR are separate gated
///    actions executed only on click.
///  - The agent process gets an explicit allow/deny tool list: edits and local
///    commands allowed, `git push` / `gh pr *` denied at the CLI permission
///    layer — not just prompt instructions.
@MainActor
final class TaskRunner: ObservableObject {

    /// Live per-run UI state (transcript tail etc.) — store holds the record.
    @Published private(set) var activeRunIds: Set<UUID> = []

    private let store: TaskStore
    private let provider: AutomationProvider
    /// Each provider call owns its child process. TaskRunner keeps only the
    /// cancellation capability, never the provider's Process instance.
    private var cancellations: [UUID: AutomationCancellation] = [:]
    private var planningText: [UUID: String] = [:]
    private var stallTimers: [UUID: DispatchWorkItem] = [:]
    private var hardCapTimers: [UUID: DispatchWorkItem] = [:]
    private var repoLocks: Set<String> = []             // FR47 per-repo mutex
    private var queuedTaskIds: [UUID] = []
    private var isCancellingAll = false

    /// FR47 concurrency cap.
    private let maxConcurrent = 2
    /// FR50 timeouts.
    private let stallTimeout: TimeInterval = 10 * 60
    private let hardCap: TimeInterval = 45 * 60

    var onEvent: ((String, UUID) -> Void)?              // (message, taskId) → notifications
    /// Fired when a run lands in a human gate (plan / review) — carries the
    /// runId so notifications can offer one-click approve/reject.
    var onGate: ((TaskGate, String, UUID, UUID) -> Void)?  // (gate, message, taskId, runId)
    /// Fired when a task reaches `done` — the board should re-rank (FR39).
    var onTaskCompleted: (() -> Void)?

    init(store: TaskStore, provider: AutomationProvider) {
        self.store = store
        self.provider = provider
    }

    /// Task 6 injects the selected provider. Keep the current AppCoordinator
    /// construction source-compatible until that migration lands.
    convenience init(store: TaskStore, binaryPath: String) {
        self.init(store: store, provider: ClaudeAutomationProvider(binaryPath: binaryPath,
                                                                     version: "compatibility"))
    }

    // MARK: - Phase 1: Plan (FR44.1)

    /// Start a run: generate the plan, land the task in the plan gate.
    func startRun(taskId: UUID) {
        guard var task = store.task(taskId), task.isRunnable else { return }
        guard !(task.taskKind == .code && (task.workspacePath ?? "").isEmpty) else { return }

        // Concurrency / repo mutex → queue (FR47).
        if activeRunIds.count >= maxConcurrent || isRepoLocked(task) {
            task.status = .queued
            store.update(task)
            if !queuedTaskIds.contains(taskId) { queuedTaskIds.append(taskId) }
            return
        }

        task.status = .planning
        store.update(task)
        lockRepo(task)

        let run = store.addRun(TaskRun(taskId: taskId, agentId: task.agentId,
                                       provider: provider.descriptor.kind,
                                       workspacePath: task.workspacePath ?? ""))
        activeRunIds.insert(run.id)

        let prompt = """
        You are planning (NOT executing) a task. Produce a concise execution plan \
        as markdown: "## Plan" with 2-6 numbered steps, "## Touches" listing \
        files/systems affected, "## Boundary actions" listing any actions that \
        would leave this machine (push, PR, external posts) — these will be done \
        separately by a human. Do not perform any action. Task:

        # \(task.title)
        \(task.descriptionMD)
        \(task.sourceSnapshot.isEmpty ? "" : "Source context:\n\(task.sourceSnapshot)")
        """

        let profile = Preferences.shared.agent(task.agentId)
        startPlanning(runID: run.id, taskID: taskId, prompt: prompt,
                      workingDirectory: task.workspacePath,
                      model: Self.resolveModel(task: task, profile: profile),
                      systemPrompt: profile?.systemPrompt)
    }

    private func startPlanning(runID: UUID, taskID: UUID, prompt: String,
                               workingDirectory: String?, model: String?, systemPrompt: String?) {
        planningText[runID] = ""
        let request = AutomationRequest(
            prompt: prompt,
            model: model,
            workingDirectory: workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) },
            timeout: 240,
            systemPrompt: systemPrompt
        )
        let cancellation = provider.runText(request) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handlePlanningEvent(event, runID: runID, taskID: taskID)
            }
        }
        guard activeRunIds.contains(runID), store.run(runID)?.state.isTerminal == false else {
            cancellation.cancel()
            return
        }
        cancellations[runID] = cancellation
    }

    private func handlePlanningEvent(_ event: AutomationEvent, runID: UUID, taskID: UUID) {
        guard let run = store.run(runID), !run.state.isTerminal else { return }
        switch event {
        case .sessionID(let sessionID):
            persist(sessionID: sessionID, for: runID)
        case .text(let text):
            planningText[runID, default: ""] += text
        case .completed:
            let plan = planningText.removeValue(forKey: runID) ?? ""
            cancellations[runID] = nil
            completePlanning(runID: runID, taskID: taskID, plan: plan)
        case .failed(let reason):
            planningText[runID] = nil
            finishRun(runID, state: .failed, reason: reason)
        }
    }

    private func completePlanning(runID: UUID, taskID: UUID, plan: String) {
        guard var run = store.run(runID), var task = store.task(taskID), !run.state.isTerminal else { return }
        guard !plan.isEmpty else {
            finishRun(runID, state: .failed,
                      reason: "Couldn't generate a plan (\(provider.descriptor.displayName) error).")
            return
        }
        run.plan = plan
        store.updateRun(run)

        // §6 A7: auto-approve small, non-code, boundary-free plans when the
        // user has the policy on. Code is always gated.
        if Self.planAutoApprovable(task: task, plan: plan) {
            store.record(ApprovalRecord(
                taskId: task.id, runId: run.id, gate: .plan,
                decision: .approved, detail: "auto-approved by policy (non-code, small, no boundary actions)"))
            task.status = .executing
            store.update(task)
            execute(runId: run.id, guidance: nil)
        } else {
            task.status = .awaitingPlanApproval
            store.update(task)
            onGate?(.plan, "Plan ready for “\(task.title)”", taskID, run.id)
        }
    }

    private func persist(sessionID: String, for runID: UUID) {
        guard var run = store.run(runID), !run.state.isTerminal else { return }
        run.cliSessionID = sessionID
        if provider.descriptor.kind == .claude, run.claudeSessionId == nil {
            run.claudeSessionId = sessionID
        }
        store.updateRun(run)
    }

    /// Model precedence: explicit task override → agent preference → opus.
    static func resolveModel(task: TaskItem, profile: AgentProfile?) -> String? {
        task.runModel ?? profile?.preferredModel ?? "opus"
    }

    /// A7 policy: ALL of — policy enabled; kind research/writing/other;
    /// estimate ≤ 1 hour; the plan's boundary-actions section says none.
    static func planAutoApprovable(task: TaskItem, plan: String) -> Bool {
        guard Preferences.shared.autoPlanApprove else { return false }
        guard task.taskKind != .code else { return false }
        switch task.estimate {
        case .minutes, .hour, .none: break
        case .halfday, .dayPlus: return false
        }
        // Boundary section must exist and declare none — anything else gates.
        let lower = plan.lowercased()
        guard let range = lower.range(of: "boundary actions") else { return false }
        let section = lower[range.upperBound...].prefix(120)
        return section.contains("none")
    }

    // MARK: - Phase 2: Plan gate (FR44.2, §6 A7)

    func approvePlan(runId: UUID, guidance: String? = nil) {
        guard var run = store.run(runId), var task = store.task(run.taskId) else { return }
        run.planApprovedAt = Date()
        store.updateRun(run)
        store.record(ApprovalRecord(taskId: task.id, runId: runId, gate: .plan,
                                    decision: guidance == nil ? .approved : .editedThenApproved,
                                    detail: guidance ?? ""))
        task.status = .executing
        store.update(task)
        execute(runId: runId, guidance: guidance)
    }

    func rejectPlan(runId: UUID, reason: String = "") {
        guard var run = store.run(runId), var task = store.task(run.taskId) else { return }
        run.state = .planRejected
        run.endedAt = Date()
        store.updateRun(run)
        store.record(ApprovalRecord(taskId: task.id, runId: runId, gate: .plan,
                                    decision: .rejected, detail: reason))
        task.status = .ready
        store.update(task)
        cleanup(runId: runId, task: task)
    }

    // MARK: - Phase 3: Execute (FR44.3, FR45–46)

    private func execute(runId: UUID, guidance: String?) {
        guard var run = store.run(runId), let task = store.task(run.taskId) else { return }

        // Workspace: worktree for code (FR45), scratch dir otherwise (FR46).
        let workspace: URL
        if task.taskKind == .code, let repoPath = task.workspacePath {
            switch GitWorktree.create(repoPath: repoPath, taskId: task.id) {
            case .success(let wt):
                workspace = wt.dir
                run.branchName = wt.branch
                run.workspacePath = wt.dir.path
            case .failure(let err):
                finishRun(runId, state: .failed, reason: "Worktree setup failed: \(err.localizedDescription)")
                return
            }
        } else {
            workspace = FileManager.default.temporaryDirectory
                .appendingPathComponent("glance-task-\(task.id.uuidString.prefix(8))", isDirectory: true)
            try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            run.workspacePath = workspace.path
        }
        store.updateRun(run)

        let transcriptDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Glance/transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        let transcriptURL = transcriptDir.appendingPathComponent("\(runId.uuidString).jsonl")
        FileManager.default.createFile(atPath: transcriptURL.path, contents: nil)
        run.transcriptPath = transcriptURL.path
        store.updateRun(run)

        let prompt = """
        Execute this task in the current directory. An approved plan follows — \
        stick to it. Rules: work only inside this directory; NEVER run `git push`, \
        never create PRs, never post to external services — a human does those \
        after review. For code: commit your work with clear messages. When done, \
        summarize what you did in 2-4 sentences as your final message.
        \(guidance.map { "Additional user guidance: \($0)" } ?? "")

        # Task: \(task.title)
        \(task.descriptionMD)

        # Approved plan
        \(run.plan)
        """
        let profile = Preferences.shared.agent(task.agentId)
        // Profiles can NARROW the toolset; boundary denies below apply always.
        let tools = profile?.allowedTools
            ?? ["Bash", "Edit", "Write", "Read", "Glob", "Grep", "WebFetch", "WebSearch"]
        // --allowedTools only ADDS grants — the user's global settings may
        // already allow e.g. Bash. Deny wins, so explicitly disallow every
        // vocabulary tool the profile leaves out, plus the boundary rules.
        let denied = AgentProfile.toolVocabulary.filter { !tools.contains($0) }
        let request = AutomationRunRequest(
            prompt: prompt,
            model: Self.resolveModel(task: task, profile: profile),
            workingDirectory: workspace,
            transcriptURL: transcriptURL,
            allowedTools: tools,
            disallowedTools: denied + ["Bash(git push:*)", "Bash(gh pr:*)", "Bash(gh api:*)"],
            systemPrompt: profile?.systemPrompt,
            sandbox: "workspace-write",
            timeout: hardCap + 60
        )
        armStallTimer(runId)
        armHardCap(runId)
        let cancellation = provider.startRun(request) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleExecutionEvent(event, runId: runId)
            }
        }
        guard activeRunIds.contains(runId), store.run(runId)?.state.isTerminal == false else {
            cancellation.cancel()
            return
        }
        cancellations[runId] = cancellation
    }

    private func handleExecutionEvent(_ event: AutomationEvent, runId: UUID) {
        guard let run = store.run(runId), !run.state.isTerminal else { return }
        appendTranscript(event, runId: runId)
        switch event {
        case .sessionID(let sessionID):
            persist(sessionID: sessionID, for: runId)
        case .text(let text):
            guard !text.isEmpty, var current = store.run(runId) else { return }
            armStallTimer(runId) // output = alive (FR50)
            current.progressTail = String((current.progressTail + text).suffix(2000))
            store.updateRun(current)
        case .completed:
            executionEnded(runId: runId)
        case .failed(let reason):
            finishRun(runId, state: .failed, reason: reason)
        }
    }

    private func executionEnded(runId: UUID) {
        guard let run = store.run(runId), !run.state.isTerminal else { return }
        clearTimers(runId)
        cancellations[runId] = nil
        guard let task = store.task(run.taskId) else { return }
        packageArtifacts(runId: runId, task: task)
    }

    /// Keep the transcript app-owned and provider-neutral. Providers expose
    /// normalized events, so neither Codex's external thread log nor Claude's
    /// raw stream format becomes part of persisted task history.
    private func appendTranscript(_ event: AutomationEvent, runId: UUID) {
        guard let path = store.run(runId)?.transcriptPath,
              let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        let record: [String: String]
        switch event {
        case .text(let text): record = ["type": "text", "text": text]
        case .sessionID(let id): record = ["type": "session", "id": id]
        case .completed: record = ["type": "completed"]
        case .failed(let reason): record = ["type": "failed", "reason": reason]
        }
        guard var data = try? JSONSerialization.data(withJSONObject: record) else { return }
        data.append(0x0A)
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    // MARK: - Phase 4: Package artifacts + review gate (FR44.4, FR52)

    private func packageArtifacts(runId: UUID, task: TaskItem) {
        guard var run = store.run(runId) else { return }
        var artifacts: [RunArtifact] = []

        if task.taskKind == .code, let branch = run.branchName {
            let stat = GitWorktree.diffStat(workspace: run.workspacePath, baseBranch: nil)
            artifacts.append(RunArtifact(kind: .diff,
                                         summary: stat.isEmpty ? "No changes" : stat,
                                         payloadRef: run.workspacePath))
            artifacts.append(RunArtifact(kind: .branch,
                                         summary: "Branch \(branch)",
                                         payloadRef: branch))
            artifacts.append(RunArtifact(kind: .externalWrite,
                                         summary: "Push \(branch) + create draft PR",
                                         payloadRef: branch,
                                         boundary: true))
        } else {
            let summary = String(run.progressTail.suffix(1500))
            artifacts.append(RunArtifact(kind: .draftText,
                                         summary: "Result draft",
                                         payloadRef: summary))
        }

        run.artifacts = artifacts
        run.state = .succeeded
        run.endedAt = Date()
        store.updateRun(run)

        var t = task
        t.status = .awaitingReview
        store.update(t)
        unlockRepo(t)
        activeRunIds.remove(runId)
        onGate?(.review, "“\(task.title)” finished — awaiting your review", task.id, runId)
        startNextQueued()
    }

    // MARK: - Phase 5: Review gate (FR52–53)

    func approveReview(runId: UUID, releaseBoundary: Bool) {
        guard let run = store.run(runId), var task = store.task(run.taskId) else { return }
        store.record(ApprovalRecord(taskId: task.id, runId: runId, gate: .review,
                                    decision: .approved))
        task.status = .done
        task.completedAt = Date()
        store.update(task)
        onTaskCompleted?()

        if releaseBoundary {
            for artifact in run.artifacts where artifact.boundary && !artifact.released {
                releaseBoundaryAction(runId: runId, artifactId: artifact.id)
            }
        }
        // Worktree kept on approve (branch is the deliverable) — FR45.
    }

    func rejectReview(runId: UUID, reason: String) {
        guard var run = store.run(runId), var task = store.task(run.taskId) else { return }
        store.record(ApprovalRecord(taskId: task.id, runId: runId, gate: .review,
                                    decision: .rejected, detail: reason))
        task.status = .ready
        store.update(task)
        // Rejected code run: discard the worktree (FR45).
        if task.taskKind == .code, !run.workspacePath.isEmpty {
            GitWorktree.remove(workspace: run.workspacePath, repoPath: task.workspacePath)
        }
        run.progressTail += "\n[review rejected: \(reason)]"
        store.updateRun(run)
    }

    /// Execute one gated boundary action (FR53): push + draft PR.
    func releaseBoundaryAction(runId: UUID, artifactId: UUID) {
        guard let run = store.run(runId), let task = store.task(run.taskId),
              let idx = run.artifacts.firstIndex(where: { $0.id == artifactId }),
              run.artifacts[idx].boundary, !run.artifacts[idx].released else { return }
        let branch = run.artifacts[idx].payloadRef
        let workspace = run.workspacePath

        store.record(ApprovalRecord(taskId: task.id, runId: runId, gate: .boundaryAction,
                                    decision: .approved, detail: run.artifacts[idx].summary))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pushResult = Self.shell(["git", "push", "-u", "origin", branch], cwd: workspace)
            var prURL: String?
            if pushResult.status == 0 {
                let pr = Self.shell(["gh", "pr", "create", "--draft", "--fill", "--head", branch], cwd: workspace)
                if pr.status == 0 { prURL = pr.output.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            Task { @MainActor [weak self] in
                guard let self, var run = self.store.run(runId),
                      let idx = run.artifacts.firstIndex(where: { $0.id == artifactId }) else { return }
                if pushResult.status == 0 {
                    run.artifacts[idx].released = true
                    if let prURL {
                        run.artifacts.append(RunArtifact(kind: .prURL, summary: "Draft PR", payloadRef: prURL))
                    }
                    self.onEvent?("Pushed \(branch)\(prURL != nil ? " + draft PR created" : "")", task.id)
                } else {
                    run.artifacts[idx].summary += " — FAILED: \(String(pushResult.output.suffix(200)))"
                    self.onEvent?("Push failed for \(branch)", task.id)
                }
                self.store.updateRun(run)
            }
        }
    }

    // MARK: - Cancel / failure (FR48, FR51)

    func cancelRun(runId: UUID, reason: String = "Cancelled by user.") {
        finishRun(runId, state: .cancelled, reason: reason)
    }

    var hasActiveRuns: Bool { !activeRunIds.isEmpty }

    func cancelAll(reason: String = "Cancelled by user.") {
        // Provider changes are a session boundary: do not let the cleanup of
        // one cancelled run launch queued work through the old provider.
        isCancellingAll = true
        let queued = queuedTaskIds
        queuedTaskIds.removeAll()
        for taskID in queued where store.task(taskID)?.status == .queued {
            store.setStatus(taskID, .ready)
        }
        let active = activeRunIds
        for id in active { cancelRun(runId: id, reason: reason) }
        isCancellingAll = false
    }

    private func finishRun(_ runId: UUID, state: RunState, reason: String?) {
        clearTimers(runId)
        planningText[runId] = nil
        cancellations.removeValue(forKey: runId)?.cancel()
        guard var run = store.run(runId) else { return }
        guard !run.state.isTerminal else { return }
        run.state = state
        run.failureReason = reason
        run.endedAt = Date()
        store.updateRun(run)
        if var task = store.task(run.taskId) {
            task.status = (state == .cancelled) ? .ready : .failed
            store.update(task)
            unlockRepo(task)
            if state == .failed { onEvent?("“\(task.title)” failed — \(reason ?? "")", task.id) }
        }
        activeRunIds.remove(runId)
        if !isCancellingAll { startNextQueued() }
    }

    private func cleanup(runId: UUID, task: TaskItem) {
        activeRunIds.remove(runId)
        unlockRepo(task)
        if !isCancellingAll { startNextQueued() }
    }

    // MARK: - Queue / mutex (FR47)

    private func startNextQueued() {
        guard !isCancellingAll, activeRunIds.count < maxConcurrent, !queuedTaskIds.isEmpty else { return }
        let next = queuedTaskIds.removeFirst()
        if var t = store.task(next), t.status == .queued {
            t.status = .ready
            store.update(t)
            startRun(taskId: next)
        }
    }

    private func repoKey(_ task: TaskItem) -> String? {
        guard task.taskKind == .code else { return nil }
        return task.workspacePath
    }

    private func isRepoLocked(_ task: TaskItem) -> Bool {
        guard let key = repoKey(task) else { return false }
        return repoLocks.contains(key)
    }

    private func lockRepo(_ task: TaskItem) {
        if let key = repoKey(task) { repoLocks.insert(key) }
    }

    private func unlockRepo(_ task: TaskItem) {
        if let key = repoKey(task) { repoLocks.remove(key) }
    }

    // MARK: - Timeouts (FR50)

    private func armStallTimer(_ runId: UUID) {
        stallTimers[runId]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishRun(runId, state: .timedOut,
                                reason: "No output for \(Int((self?.stallTimeout ?? 600)/60)) minutes.")
            }
        }
        stallTimers[runId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stallTimeout, execute: work)
    }

    private func armHardCap(_ runId: UUID) {
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishRun(runId, state: .timedOut,
                                reason: "Hit the \(Int((self?.hardCap ?? 2700)/60))-minute run cap. Partial work preserved.")
            }
        }
        hardCapTimers[runId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hardCap, execute: work)
    }

    private func clearTimers(_ runId: UUID) {
        stallTimers.removeValue(forKey: runId)?.cancel()
        hardCapTimers.removeValue(forKey: runId)?.cancel()
    }

    nonisolated private static func shell(_ args: [String], cwd: String) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

// MARK: - Git worktree isolation (FR45)

enum GitWorktree {

    struct Worktree {
        let dir: URL
        let branch: String
    }

    /// Fresh worktree + branch off the repo's default branch.
    static func create(repoPath: String, taskId: UUID) -> Result<Worktree, Error> {
        let short = String(taskId.uuidString.prefix(8)).lowercased()
        let branch = "glance/task-\(short)"
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Glance/worktrees/\(short)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Reuse existing worktree from a retry: remove stale one first.
        _ = run(["git", "worktree", "remove", "--force", dir.path], cwd: repoPath)
        _ = run(["git", "branch", "-D", branch], cwd: repoPath)

        // Hooks OFF for our plumbing: repo hooks (husky post-checkout etc.)
        // assume a dev shell — SSH agent, node — that a GUI app doesn't have,
        // and a failing hook aborts `worktree add` even though the checkout
        // itself succeeded (seen live with kato's submodule clone over SSH).
        let result = run(["git", "-c", "core.hooksPath=/dev/null",
                          "worktree", "add", "-b", branch, dir.path, defaultBranch(repoPath)],
                         cwd: repoPath)
        guard result.status == 0 else {
            return .failure(NSError(domain: "Glance", code: 2, userInfo: [
                NSLocalizedDescriptionKey: String(result.output.suffix(300))
            ]))
        }
        // Submodules: best-effort — private submodules over SSH may be
        // unreachable from a GUI session; the agent can still work without
        // them and will surface it if a task truly needs one.
        _ = run(["git", "-c", "core.hooksPath=/dev/null",
                 "submodule", "update", "--init", "--recursive"], cwd: dir.path)
        return .success(Worktree(dir: dir, branch: branch))
    }

    static func remove(workspace: String, repoPath: String?) {
        if let repoPath {
            _ = run(["git", "worktree", "remove", "--force", workspace], cwd: repoPath)
        } else {
            try? FileManager.default.removeItem(atPath: workspace)
        }
    }

    /// Short human diff summary vs the branch base (for the review card).
    static func diffStat(workspace: String, baseBranch: String?) -> String {
        let base = baseBranch ?? "HEAD~50" // summarize the branch's own commits
        let counts = run(["git", "diff", "--shortstat", "\(mergeBase(workspace, base))..HEAD"], cwd: workspace)
        let files = run(["git", "diff", "--name-only", "\(mergeBase(workspace, base))..HEAD"], cwd: workspace)
        let names = files.output.split(separator: "\n").prefix(8).joined(separator: ", ")
        return [counts.output.trimmingCharacters(in: .whitespacesAndNewlines), names]
            .filter { !$0.isEmpty }.joined(separator: " — ")
    }

    private static func mergeBase(_ workspace: String, _ base: String) -> String {
        let r = run(["git", "merge-base", "HEAD", base], cwd: workspace)
        let mb = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !mb.isEmpty ? mb : "HEAD"
    }

    private static func defaultBranch(_ repoPath: String) -> String {
        let r = run(["git", "symbolic-ref", "refs/remotes/origin/HEAD", "--short"], cwd: repoPath)
        if r.status == 0 {
            let name = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = name.firstIndex(of: "/") {
                return String(name[name.index(after: slash)...])
            }
        }
        // Fallback: current HEAD branch.
        let head = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd: repoPath)
        let h = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return h.isEmpty ? "main" : h
    }

    private static func run(_ args: [String], cwd: String) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
