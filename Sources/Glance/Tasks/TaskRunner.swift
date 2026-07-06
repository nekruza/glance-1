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
    private let binaryPath: String
    private var processes: [UUID: Process] = [:]        // runId → agent process
    private var stallTimers: [UUID: DispatchWorkItem] = [:]
    private var hardCapTimers: [UUID: DispatchWorkItem] = [:]
    private var repoLocks: Set<String> = []             // FR47 per-repo mutex
    private var queuedTaskIds: [UUID] = []

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

    init(store: TaskStore, binaryPath: String) {
        self.store = store
        self.binaryPath = binaryPath
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

        let run = store.addRun(TaskRun(taskId: taskId, workspacePath: task.workspacePath ?? ""))
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
        runOneShot(prompt: prompt, cwd: task.workspacePath,
                   model: Self.resolveModel(task: task, profile: profile),
                   systemPrompt: profile?.systemPrompt) { [weak self] output in
            guard let self, var run = self.store.run(run.id) else { return }
            guard var task = self.store.task(taskId) else { return }
            if let plan = output, !plan.isEmpty {
                run.plan = plan
                self.store.updateRun(run)

                // §6 A7: auto-approve small, non-code, boundary-free plans
                // when the user has the policy on. Code is always gated.
                if Self.planAutoApprovable(task: task, plan: plan) {
                    self.store.record(ApprovalRecord(
                        taskId: task.id, runId: run.id, gate: .plan,
                        decision: .approved, detail: "auto-approved by policy (non-code, small, no boundary actions)"))
                    task.status = .executing
                    self.store.update(task)
                    self.execute(runId: run.id, guidance: nil)
                } else {
                    task.status = .awaitingPlanApproval
                    self.store.update(task)
                    self.onGate?(.plan, "Plan ready for “\(task.title)”", taskId, run.id)
                }
            } else {
                self.finishRun(run.id, state: .failed, reason: "Couldn't generate a plan (Claude CLI error).")
            }
        }
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

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        // Prompt goes via STDIN: --allowedTools/--disallowedTools are variadic
        // and would swallow a trailing positional prompt argument.
        let profile = Preferences.shared.agent(task.agentId)
        // Profiles can NARROW the toolset; boundary denies below apply always.
        let tools = profile?.allowedTools
            ?? ["Bash", "Edit", "Write", "Read", "Glob", "Grep", "WebFetch", "WebSearch"]
        var args = ["-p", "--output-format", "stream-json", "--include-partial-messages", "--verbose",
                    "--allowedTools"] + tools
        // --allowedTools only ADDS grants — the user's global settings may
        // already allow e.g. Bash. Deny wins, so explicitly disallow every
        // vocabulary tool the profile leaves out, plus the boundary rules.
        let denied = AgentProfile.toolVocabulary.filter { !tools.contains($0) }
        args += ["--disallowedTools"] + denied
        args += ["Bash(git push:*)", "Bash(gh pr:*)", "Bash(gh api:*)"]
        if let persona = profile?.systemPrompt, !persona.isEmpty {
            args += ["--append-system-prompt", persona]
        }
        if let model = Self.resolveModel(task: task, profile: profile) {
            args += ["--model", model]
        }
        proc.arguments = args
        proc.currentDirectoryURL = workspace

        let inPipe = Pipe()
        let out = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = out
        proc.standardError = Pipe()

        var buffer = Data()
        let transcriptHandle = try? FileHandle(forWritingAtPath: transcriptURL.path)
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            transcriptHandle?.write(data)
            buffer.append(data)
            // Parse complete lines for progress + session id.
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = Data(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
                Task { @MainActor [weak self] in
                    self?.ingestStreamLine(lineData, runId: runId)
                }
            }
        }

        proc.terminationHandler = { [weak self] p in
            transcriptHandle?.closeFile()
            Task { @MainActor [weak self] in
                self?.executionEnded(runId: runId, exitStatus: p.terminationStatus)
            }
        }

        do {
            try proc.run()
            if let data = prompt.data(using: .utf8) {
                try? inPipe.fileHandleForWriting.write(contentsOf: data)
            }
            try? inPipe.fileHandleForWriting.close()
            processes[runId] = proc
            armStallTimer(runId)
            armHardCap(runId)
        } catch {
            finishRun(runId, state: .failed, reason: "Couldn't launch agent: \(error.localizedDescription)")
        }
    }

    private func ingestStreamLine(_ data: Data, runId: UUID) {
        guard var run = store.run(runId) else { return }
        guard let line = try? JSONDecoder().decode(StreamLine.self, from: data) else { return }
        if let sid = line.sessionId, run.claudeSessionId == nil {
            run.claudeSessionId = sid
            store.updateRun(run)
        }
        if let text = line.streamedText, !text.isEmpty {
            armStallTimer(runId) // output = alive (FR50)
            run.progressTail = String((run.progressTail + text).suffix(2000))
            store.updateRun(run)
        }
        if line.isResult, line.isError == true {
            // surfaced at exit; nothing to do here
        }
    }

    private func executionEnded(runId: UUID, exitStatus: Int32) {
        guard let run = store.run(runId), !run.state.isTerminal else { return }
        clearTimers(runId)
        processes[runId] = nil
        guard let task = store.task(run.taskId) else { return }

        if exitStatus != 0 {
            finishRun(runId, state: .failed,
                      reason: "Agent exited with status \(exitStatus). See transcript.")
            return
        }
        packageArtifacts(runId: runId, task: task)
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
        guard var run = store.run(runId), let task = store.task(run.taskId),
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

    func cancelRun(runId: UUID) {
        processes[runId]?.terminate()
        finishRun(runId, state: .cancelled, reason: "Cancelled by user.")
    }

    var hasActiveRuns: Bool { !activeRunIds.isEmpty }

    func cancelAll() {
        for id in activeRunIds { cancelRun(runId: id) }
    }

    private func finishRun(_ runId: UUID, state: RunState, reason: String?) {
        clearTimers(runId)
        processes[runId]?.terminate()
        processes[runId] = nil
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
            cleanup(runId: runId, task: task)
            if state == .failed { onEvent?("“\(task.title)” failed — \(reason ?? "")", task.id) }
        }
        activeRunIds.remove(runId)
        startNextQueued()
    }

    private func cleanup(runId: UUID, task: TaskItem) {
        activeRunIds.remove(runId)
        unlockRepo(task)
        startNextQueued()
    }

    // MARK: - Queue / mutex (FR47)

    private func startNextQueued() {
        guard activeRunIds.count < maxConcurrent, !queuedTaskIds.isEmpty else { return }
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

    // MARK: - One-shot helper (plan phase)

    private func runOneShot(prompt: String, cwd: String?, model: String? = nil,
                            systemPrompt: String? = nil,
                            completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [binaryPath] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binaryPath)
            var args = ["-p"]
            if let model { args += ["--model", model] }
            if let systemPrompt, !systemPrompt.isEmpty {
                args += ["--append-system-prompt", systemPrompt]
            }
            args.append(prompt)
            proc.arguments = args
            if let cwd, !cwd.isEmpty {
                proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
            } else {
                proc.currentDirectoryURL = FileManager.default.temporaryDirectory
            }
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()
            var text: String?
            do {
                try proc.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    text = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch { /* nil */ }
            DispatchQueue.main.async { completion(text) }
        }
    }

    private static func shell(_ args: [String], cwd: String) -> (status: Int32, output: String) {
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
