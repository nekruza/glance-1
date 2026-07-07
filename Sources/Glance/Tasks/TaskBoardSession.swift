import SwiftUI

/// View-model for the task board overlay (F1/F2): tab state, quick-add,
/// prompt-decomposition preview, selection, and the AI triggers (enrichment
/// on create, batched re-prioritization).
@MainActor
final class TaskBoardSession: ObservableObject {

    enum Tab: String, CaseIterable {
        // Declaration order = tab order: Inbox (triage) first, then the board,
        // then the human-gate Review queue, then Done.
        case inbox = "Inbox", board = "Board", review = "Review", done = "Done"
    }

    struct ActivityEvent: Identifiable {
        let id = UUID()
        let at: Date
        let icon: String
        let text: String
    }

    enum SortMode: String, CaseIterable {
        case aiRank = "AI order", priority = "Priority", dateAdded = "Date added"
    }

    @Published var tab: Tab = .board
    @Published var showSettings = false
    @Published var sortMode: SortMode = .aiRank
    @Published var quickAdd: String = ""
    @Published var searchText: String = ""
    @Published var selectedTaskId: UUID? {
        didSet { if selectedTaskId == nil { detailFullPage = false } }
    }
    /// false = detail slides in as a right-side drawer over the current tab;
    /// true = detail takes over the whole page (expand button in the drawer).
    @Published var detailFullPage = false
    @Published var isPrioritizing = false

    /// Prompt→tasks flow (FR27): text in, preview list out, user confirms.
    @Published var decomposeMode = false
    @Published var decomposeText = ""
    @Published var decomposeBusy = false
    @Published var decomposePreview: [TaskAI.DecomposedTask] = []
    @Published var decomposeKeep: Set<Int> = []

    /// Composio pull state (header button + status line).
    @Published var pullingSource: ComposioIngest.Source?
    @Published var pullStatus: String?

    /// Tasks with a handoff-prompt generation in flight (detail spinner).
    @Published var promptBusyTaskIds: Set<UUID> = []
    /// Tasks with meeting prep-notes generation in flight (detail spinner),
    /// with the current phase for the label.
    @Published var prepBusyTaskIds: Set<UUID> = []
    @Published var prepPhase: String = "Gathering context…"
    /// Tasks with a helper-draft generation in flight (reply/draft/brief/approach).
    @Published var draftBusyTaskIds: Set<UUID> = []
    /// Tasks with an approved outbound send in flight (review-queue spinner).
    @Published var sendBusyTaskIds: Set<UUID> = []
    /// Last send failure per task (surfaced in the draft-review gate).
    @Published var sendError: [UUID: String] = [:]

    /// Canvas completion choreography: tasks mid check-animation (still
    /// rendered), live confetti bursts, and the undo toast.
    @Published var completingTaskIds: Set<UUID> = []
    @Published var confettiBursts: [ConfettiBurst] = []
    @Published var undoToast: UndoToast?
    /// Floating quick-capture card (N key / pill +).
    @Published var showCapture = false
    /// Most recently created task — drives the pop-in animation on canvas.
    @Published var lastCreatedTaskId: UUID?

    struct UndoToast: Equatable {
        let taskId: UUID
        let title: String
    }

    let store: TaskStore
    let runner: TaskRunner
    private let ai: TaskAI
    private let ingest: ComposioIngest
    /// Shared last-working-day digests (Granola/Slack/Jira/GitHub) — TTL
    /// cache so prep notes across meetings reuse one fetch per source.
    private(set) lazy var workContext = WorkContext(ingest: ingest)

    var dismissHandler: (() -> Void)?
    var settingsHandler: (() -> Void)?
    /// Opens the ask overlay (settings-page footer shortcut).
    var openAskHandler: (() -> Void)?
    /// Wired to notifications — fired when a pull lands new Inbox items
    /// (matters for scheduled pulls with the overlay closed).
    var pullNotifyHandler: ((String) -> Void)?
    /// Wired to notifications — fired when an approved outbound send succeeds
    /// or an autopilot draft lands in the Review queue.
    var sendNotifyHandler: ((String, UUID) -> Void)?

    private var lastPrioritized = Date.distantPast
    /// FR42: at most one automatic reflow per 10 minutes.
    private let reflowInterval: TimeInterval = 10 * 60

    init(store: TaskStore, runner: TaskRunner, ai: TaskAI, ingest: ComposioIngest) {
        self.store = store
        self.runner = runner
        self.ai = ai
        self.ingest = ingest
    }

    /// Settings ▸ Agents passthrough: Opus designs a profile from a request.
    func generateAgent(request: String, completion: @escaping (AgentProfile?) -> Void) {
        let existing = Preferences.shared.agents.map(\.name)
        ai.generateAgent(request: request, existingNames: existing) { g in
            guard let g else {
                completion(nil)
                return
            }
            let tools = (g.allowedTools ?? ["Read", "Glob", "Grep"])
                .filter { AgentProfile.toolVocabulary.contains($0) }
            let model: String? = ["haiku", "sonnet", "opus"].contains(g.preferredModel ?? "")
                ? g.preferredModel : nil
            let profile = AgentProfile(
                name: String(g.name.prefix(40)),
                icon: g.icon?.isEmpty == false ? g.icon! : "person",
                skills: g.skills,
                systemPrompt: g.systemPrompt,
                preferredModel: model,
                allowedTools: tools.isEmpty ? ["Read", "Glob", "Grep"] : tools
            )
            completion(profile)
        }
    }

    /// Settings ▸ Connections passthrough (ingest is private).
    func listConnections(completion: @escaping ([ComposioIngest.Connection]?, String?) -> Void) {
        ingest.listConnections(completion: completion)
    }

    // MARK: - Composio pulls (manual, read-only)

    func pull(_ source: ComposioIngest.Source) {
        guard pullingSource == nil, ensureComposioConfigured() else { return }
        pullingSource = source
        pullStatus = nil
        ingest.pull(source, store: store) { [weak self] result in
            guard let self else { return }
            self.pullingSource = nil
            self.showPullStatus(Self.describe(source, result))
            self.autoTriage(result.createdIds)
            if result.created > 0 {
                self.tab = .inbox
                self.pullNotifyHandler?("\(source.rawValue): \(result.created) new task\(result.created == 1 ? "" : "s") in Inbox")
            }
        }
    }

    /// Pull every source, one at a time (a single agent call each), then show
    /// an aggregate status line.
    func pullAll() {
        guard pullingSource == nil, ensureComposioConfigured() else { return }
        pullStatus = nil
        var summary: [String] = []
        var totalCreated = 0
        let sources = ComposioIngest.Source.allCases

        func next(_ index: Int) {
            guard index < sources.count else {
                pullingSource = nil
                showPullStatus(summary.joined(separator: " · "))
                if totalCreated > 0 {
                    tab = .inbox
                    pullNotifyHandler?("Pull finished: \(totalCreated) new task\(totalCreated == 1 ? "" : "s") in Inbox (\(summary.joined(separator: ", ")))")
                }
                return
            }
            let source = sources[index]
            pullingSource = source
            ingest.pull(source, store: store) { [weak self] result in
                guard let self else { return }
                totalCreated += result.created
                self.autoTriage(result.createdIds)
                if result.error != nil {
                    summary.append("\(source.rawValue) ✗")
                } else {
                    summary.append("\(source.rawValue) +\(result.created)")
                }
                next(index + 1)
            }
        }
        next(0)
    }

    private func ensureComposioConfigured() -> Bool {
        if Preferences.shared.composioKey.isEmpty {
            pullStatus = "Set your Composio API key in Settings first."
            return false
        }
        return true
    }

    private static func describe(_ source: ComposioIngest.Source, _ result: ComposioIngest.Result) -> String {
        if let error = result.error { return "\(source.rawValue): \(error)" }
        if result.created == 0 {
            return "\(source.rawValue): nothing new"
                + (result.skippedDuplicates > 0 ? " (\(result.skippedDuplicates) already on board)" : "")
        }
        return "\(source.rawValue): \(result.created) new in Inbox"
            + (result.skippedDuplicates > 0 ? ", \(result.skippedDuplicates) known" : "")
    }

    private func showPullStatus(_ text: String) {
        pullStatus = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.pullStatus = nil
        }
    }

    // MARK: - Lists

    func visibleTasks() -> [TaskItem] {
        var base: [TaskItem]
        switch tab {
        case .board:  base = store.boardTasks()
        case .inbox:  base = store.inboxTasks()
        case .review: base = reviewTasks()
        case .done:   base = store.doneTasks()
        }
        // Alternative sorts for the board (AI order comes pre-sorted, pins first).
        if tab == .board {
            switch sortMode {
            case .aiRank: break
            case .priority:
                base.sort { ($0.aiPriority, $0.aiRank) < ($1.aiPriority, $1.aiRank) }
            case .dateAdded:
                base.sort { $0.createdAt > $1.createdAt }
            }
        }
        guard !searchQuery.isEmpty else { return base }
        return base.filter(matchesSearch)
    }

    /// Board tasks in sorted order WITHOUT the search filter — the canvas
    /// dims non-matches instead of removing them (spatial memory survives).
    func canvasTasks() -> [TaskItem] {
        var base = store.boardTasks()
        switch sortMode {
        case .aiRank: break
        case .priority:
            base.sort { ($0.aiPriority, $0.aiRank) < ($1.aiPriority, $1.aiRank) }
        case .dateAdded:
            base.sort { $0.createdAt > $1.createdAt }
        }
        return base
    }

    /// Inbox tasks for the inbox canvas — newest first, search dims not filters.
    func inboxCanvasTasks() -> [TaskItem] {
        store.inboxTasks()
    }

    /// Everything parked at a human gate — plan approval, run review, or a
    /// draft awaiting send/approve. Feeds the Review tab + queue. Most recently
    /// updated first (freshest gate on top).
    func reviewTasks() -> [TaskItem] {
        store.tasks
            .filter { $0.status == .awaitingPlanApproval || $0.status == .awaitingReview }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespaces).lowercased()
    }

    func matchesSearch(_ task: TaskItem) -> Bool {
        let q = searchQuery
        guard !q.isEmpty else { return true }
        return task.title.lowercased().contains(q)
            || task.labels.contains { $0.lowercased().contains(q) }
            || task.descriptionMD.lowercased().contains(q)
    }

    var selectedTask: TaskItem? {
        selectedTaskId.flatMap { store.task($0) }
    }

    /// Latest run for the selected task (drives gates in the detail view).
    var selectedRun: TaskRun? {
        guard let id = selectedTaskId else { return nil }
        return store.runs(for: id).first
    }

    // MARK: - Creation (FR26–27)

    func submitQuickAdd() {
        let text = quickAdd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        quickAdd = ""
        createTask(title: text)
    }

    /// Full create path (CaptureCard): title is required, everything else is
    /// optional. When `enrich` is true (default), whatever the user leaves
    /// blank gets AI-drafted from the title alone (description/labels/kind/
    /// estimate/agent — only fields not already set here); false = exactly
    /// what was typed, no AI call.
    @discardableResult
    func createTask(title: String, description: String = "", labels: [String] = [],
                    agentId: UUID? = nil, runModel: String? = nil,
                    dueAt: Date? = nil, enrich shouldEnrich: Bool = true) -> TaskItem? {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var t = TaskItem(title: text, source: .manual)
        t.descriptionMD = description.trimmingCharacters(in: .whitespacesAndNewlines)
        t.labels = labels
        t.agentId = agentId
        t.runModel = runModel
        t.dueAt = dueAt
        let added = store.add(t)
        lastCreatedTaskId = added.id
        if shouldEnrich { enrich(added) }
        return added
    }

    func startDecompose() {
        decomposeMode = true
        decomposeText = ""
        decomposePreview = []
        decomposeKeep = []
    }

    func runDecompose() {
        let text = decomposeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !decomposeBusy else { return }
        decomposeBusy = true
        ai.decompose(prompt: text) { [weak self] result in
            guard let self else { return }
            self.decomposeBusy = false
            self.decomposePreview = result ?? []
            self.decomposeKeep = Set(self.decomposePreview.indices)
        }
    }

    /// FR27: user confirms which decomposed tasks land.
    func confirmDecompose() {
        for (i, d) in decomposePreview.enumerated() where decomposeKeep.contains(i) {
            var t = TaskItem(title: d.title, source: .prompt)
            t.descriptionMD = d.description ?? ""
            t.labels = d.labels ?? []
            t.taskKind = TaskKind(rawValue: d.taskKind ?? "") ?? .other
            t.estimate = TaskEstimate(rawValue: d.estimate ?? "")
            t.agentId = AgentProfile.idFor(name: d.agent)
            t.aiFilledFields = ["description", "labels", "taskKind", "estimate", "agent"]
            store.add(t)
        }
        decomposeMode = false
        decomposePreview = []
    }

    // MARK: - AI triggers

    /// FR36/FR38: async enrichment; user edits win (only fills empty fields).
    private func enrich(_ task: TaskItem) {
        let repoNames = Preferences.shared.repos.map(\.name)
        ai.enrich(title: task.title, description: task.descriptionMD, repoNames: repoNames) { [weak self] e in
            guard let self, let e, var t = self.store.task(task.id) else { return }
            var filled: [String] = []
            if let title = e.title, !title.isEmpty, title != t.title, t.title == task.title {
                t.title = title; filled.append("title")
            }
            if t.descriptionMD.isEmpty, let d = e.description, !d.isEmpty {
                t.descriptionMD = d; filled.append("description")
            }
            if t.labels.isEmpty, let l = e.labels { t.labels = l; filled.append("labels") }
            if t.taskKind == .other, let k = e.taskKind, let kind = TaskKind(rawValue: k) {
                t.taskKind = kind; filled.append("taskKind")
            }
            if t.estimate == nil, let est = e.estimate, let parsed = TaskEstimate(rawValue: est) {
                t.estimate = parsed; filled.append("estimate")
            }
            if t.workspacePath == nil, let repo = e.repoName,
               let entry = Preferences.shared.repos.first(where: { $0.name == repo }) {
                t.workspacePath = entry.path; filled.append("workspace")
            }
            if t.agentId == nil, let agentId = AgentProfile.idFor(name: e.agent) {
                t.agentId = agentId; filled.append("agent")
            }
            t.aiFilledFields = Array(Set(t.aiFilledFields + filled))
            self.store.update(t)
        }
    }

    /// Prioritization is MANUAL-ONLY (user decision, overriding FR39's
    /// automatic triggers): it runs solely from the wand button. New tasks
    /// simply land at the bottom until the user asks for a re-rank.
    func schedulePrioritize(force: Bool = false) {
        guard force else { return } // no automatic reflows
        let board = store.boardTasks()
        guard board.count > 1 else { return }
        lastPrioritized = Date()
        isPrioritizing = true
        ai.prioritize(board: board) { [weak self] entries in
            guard let self else { return }
            self.isPrioritizing = false
            guard let entries else { return }
            let mapped: [(UUID, String, TaskPriority)] = entries.compactMap { e in
                guard let id = UUID(uuidString: e.id) else { return nil }
                let p = TaskPriority(rawValue: e.priority.uppercased()) ?? .p2
                return (id, e.rationale, p)
            }
            self.store.applyPrioritization(mapped.map { (id: $0.0, rationale: $0.1, priority: $0.2) })
        }
    }

    /// Create prompt (code tasks): AI writes a paste-into-another-assistant
    /// prompt; saved on the task so it survives restarts. Failure = no change.
    func generateHandoffPrompt(_ task: TaskItem) {
        guard !promptBusyTaskIds.contains(task.id) else { return }
        promptBusyTaskIds.insert(task.id)
        let repoName = Preferences.shared.repos.first { $0.path == task.workspacePath }?.name
        let agent = Preferences.shared.agent(task.agentId)
        ai.handoffPrompt(for: task, repoName: repoName, agent: agent) { [weak self] text in
            guard let self else { return }
            self.promptBusyTaskIds.remove(task.id)
            guard let text, var t = self.store.task(task.id) else { return }
            t.handoffPrompt = text
            self.store.update(t)
        }
    }

    /// Prep notes (meeting tasks): gather last-working-day digests from
    /// Granola/Slack/Jira/GitHub (cached in WorkContext — no double fetch),
    /// then AI writes grounded prep notes; saved on the task so they survive
    /// restarts. Failure = no change.
    func generatePrepNotes(_ task: TaskItem) {
        guard !prepBusyTaskIds.contains(task.id) else { return }
        prepBusyTaskIds.insert(task.id)
        prepPhase = "Gathering context…"
        let boardContext = boardDigest(excluding: task.id)
        workContext.digests { [weak self] digests in
            guard let self else { return }
            self.prepPhase = "Writing notes…"
            self.ai.prepNotes(for: task, workDigests: digests,
                              boardContext: boardContext) { [weak self] text in
                guard let self else { return }
                self.prepBusyTaskIds.remove(task.id)
                guard let text, var t = self.store.task(task.id) else { return }
                t.prepNotes = text
                self.store.update(t)
            }
        }
    }

    /// Helper draft (reply / writing draft / research brief / approach):
    /// AI writes the type-appropriate helper output; saved on the task so it
    /// survives restarts. Failure = no change.
    func generateHelperDraft(_ task: TaskItem, thenReview: Bool = false) {
        guard !draftBusyTaskIds.contains(task.id) else { return }
        draftBusyTaskIds.insert(task.id)
        ai.helperDraft(for: task, helper: task.helper) { [weak self] text in
            guard let self else { return }
            self.draftBusyTaskIds.remove(task.id)
            guard let text, var t = self.store.task(task.id) else { return }
            t.helperDraft = text
            // Autopilot path: park at the review gate in the same write as the
            // draft itself — a quit between the two can't strand a finished
            // draft outside Review. Only promote a task still sitting in Ready
            // (the user may have acted on it while the draft was generating).
            if thenReview, t.status == .ready {
                t.status = .awaitingReview
            }
            self.store.update(t)
            if thenReview, t.status == .awaitingReview {
                self.sendNotifyHandler?("Draft ready — \(t.title)", t.id)
            }
        }
    }

    // MARK: - Auto-triage (post-pull)

    /// Enrich each freshly-pulled inbox task, filling only fields the pull left
    /// empty (enrich never overwrites set values). Gated by autoTriageEnabled;
    /// a per-task enrich failure just leaves that task raw — no retry loop.
    private func autoTriage(_ ids: [UUID]) {
        guard Preferences.shared.autoTriageEnabled else { return }
        for id in ids {
            guard let task = store.task(id) else { continue }
            enrich(task)
        }
    }

    // MARK: - Review queue (draft gate) — approve / send / reject

    /// HARD TRUST BOUNDARY: the ONLY path that triggers an outbound write.
    /// Called exclusively from an explicit user "Approve & send" click on one
    /// task. Persists any edit first (edited text is exactly what's sent),
    /// builds a single-action instruction from the task's outboundTarget +
    /// final draft, and performs exactly one Composio write. Success →
    /// sentAt/.done/notify; failure → task stays put, error surfaced, no retry.
    /// Never reachable from Autopilot, pull, triage, or a timer.
    func approveSend(_ task: TaskItem, editedDraft: String?) {
        guard !sendBusyTaskIds.contains(task.id),
              let target = task.outboundTarget else { return }
        // Persist the edit up front so the sent text and the saved draft match.
        if let edited = editedDraft, var t = store.task(task.id), t.helperDraft != edited {
            t.helperDraft = edited
            store.update(t)
        }
        let finalText = (editedDraft ?? task.helperDraft ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else { return }

        let instruction: String
        switch target {
        case .slackReply(let permalink):
            instruction = """
            Post this message as a reply in the Slack thread at this permalink: \
            \(permalink)
            Message text:
            \(finalText)
            """
        case .jiraComment(let issueKey):
            instruction = """
            Add this comment to Jira issue \(issueKey).
            Comment text:
            \(finalText)
            """
        }

        sendBusyTaskIds.insert(task.id)
        sendError[task.id] = nil
        ingest.performWrite(instruction: instruction) { [weak self] result in
            guard let self else { return }
            self.sendBusyTaskIds.remove(task.id)
            switch result {
            case .success:
                guard var done = self.store.task(task.id) else { return }
                done.sentAt = Date()
                done.status = .done
                done.completedAt = Date()
                self.store.update(done)
                self.sendNotifyHandler?("Sent — \(task.title)", task.id)
            case .failure(let error):
                self.sendError[task.id] = error.localizedDescription
            }
        }
    }

    /// Approve a draft with no outbound target (research brief / suggested
    /// approach, or a Slack/Jira task missing its sourceRef): accept it as
    /// done. No Composio call.
    func approveDraft(_ task: TaskItem) {
        store.setStatus(task.id, .done)
    }

    /// Reject a draft in the review queue → back to Ready, draft kept for
    /// reference. No outbound anything.
    func rejectDraft(_ task: TaskItem) {
        guard var t = store.task(task.id) else { return }
        t.status = .ready
        store.update(t)
    }

    /// Compact snapshot of the local board for prep-notes grounding: what's
    /// on the canvas, what's waiting in the inbox, what got done recently.
    private func boardDigest(excluding taskId: UUID) -> String {
        func line(_ t: TaskItem) -> String {
            var bits = ["\(t.aiPriority.rawValue) \(t.title.prefix(90))"]
            if !t.labels.isEmpty { bits.append("[\(t.labels.prefix(3).joined(separator: ","))]") }
            if t.status != .ready { bits.append("(\(t.status.display))") }
            if let due = t.dueAt { bits.append("due \(due.formatted(.dateTime.month(.abbreviated).day()))") }
            return "- " + bits.joined(separator: " ")
        }
        var sections: [String] = []
        let board = store.boardTasks().filter { $0.id != taskId }.prefix(20)
        if !board.isEmpty {
            sections.append("Canvas (active work):\n" + board.map(line).joined(separator: "\n"))
        }
        let inbox = store.inboxTasks().filter { $0.id != taskId }.prefix(15)
        if !inbox.isEmpty {
            sections.append("Inbox (untriaged):\n" + inbox.map(line).joined(separator: "\n"))
        }
        // Recently finished — last 3 days covers "since last time" reporting.
        let cutoff = Date().addingTimeInterval(-3 * 86_400)
        let done = store.doneTasks()
            .filter { ($0.completedAt ?? .distantPast) > cutoff }
            .prefix(15)
        if !done.isEmpty {
            sections.append("Done recently:\n" + done.map {
                "- \($0.title.prefix(90)) (done \(($0.completedAt ?? Date()).formatted(.dateTime.month(.abbreviated).day())))"
            }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Activity feed + export (FR58–59)

    /// Chronological audit: every gate decision and run, newest first.
    func activityFeed(limit: Int = 200) -> [ActivityEvent] {
        func title(_ id: UUID) -> String {
            store.task(id)?.title ?? "(deleted task)"
        }
        var events: [ActivityEvent] = []
        for a in store.approvals {
            let gate: String
            switch a.gate {
            case .plan: gate = "Plan \(a.decision == .rejected ? "rejected" : "approved")"
            case .review: gate = "Result \(a.decision == .rejected ? "rejected" : "approved")"
            case .boundaryAction: gate = "Boundary action approved: \(a.detail)"
            case .destructiveRefusal: gate = "Destructive step refused"
            case .inboxAccept: gate = "Accepted from Inbox"
            }
            events.append(.init(at: a.decidedAt,
                                icon: a.decision == .rejected ? "xmark.circle" : "checkmark.circle",
                                text: "\(gate) — \(title(a.taskId))"))
        }
        for r in store.runs {
            events.append(.init(at: r.startedAt, icon: "play.circle",
                                text: "Run started — \(title(r.taskId))"))
            if let end = r.endedAt {
                events.append(.init(at: end,
                                    icon: r.state == .succeeded ? "flag.checkered" : "exclamationmark.circle",
                                    text: "Run \(r.state.rawValue) — \(title(r.taskId))"))
            }
        }
        return Array(events.sorted { $0.at > $1.at }.prefix(limit))
    }

    /// FR59: export the whole board + audit trail as Markdown; returns the file.
    @discardableResult
    func exportBoard() -> URL? {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Glance Tasks Export \(df.string(from: Date())).md")

        var md = "# Glance Tasks — export \(df.string(from: Date()))\n"
        let groups: [(String, [TaskItem])] = [
            ("Board", store.boardTasks()),
            ("Inbox", store.inboxTasks()),
            ("Done / Archived", store.doneTasks())
        ]
        for (name, tasks) in groups where !tasks.isEmpty {
            md += "\n## \(name)\n"
            for t in tasks {
                md += "\n### \(t.title)\n"
                md += "- \(t.aiPriority.rawValue) · \(t.status.display) · \(t.taskKind.rawValue) · \(t.source.rawValue)"
                if !t.labels.isEmpty { md += " · " + t.labels.joined(separator: ", ") }
                md += "\n"
                if !t.descriptionMD.isEmpty { md += "\n\(t.descriptionMD)\n" }
                let runs = store.runs(for: t.id)
                if !runs.isEmpty {
                    md += "\nRuns:\n"
                    for r in runs {
                        md += "- \(r.startedAt.formatted()) — \(r.state.rawValue)"
                        if let reason = r.failureReason { md += " (\(reason))" }
                        md += "\n"
                    }
                }
            }
        }
        md += "\n## Activity log\n"
        for e in activityFeed(limit: 500) {
            md += "- \(e.at.formatted()) — \(e.text)\n"
        }
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Completion (manual check — the fun part)

    /// Manual completion with celebration: check draws, sound plays, confetti
    /// bursts at `point` (canvas coords), then the card fades and the status
    /// flips to done. `point == nil` (detail view, Reduce Motion) skips the
    /// spatial confetti but keeps sound + status.
    func complete(_ task: TaskItem, at point: CGPoint? = nil) {
        guard !completingTaskIds.contains(task.id), task.status != .done else { return }
        completingTaskIds.insert(task.id)
        CompletionSound.play()
        if let point, Preferences.shared.confettiEnabled,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            confettiBursts.append(ConfettiBurst(origin: point))
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self else { return }
            // Re-fetch: the task may have been archived/run meanwhile.
            if let live = self.store.task(task.id), live.status != .done {
                self.store.setStatus(task.id, .done)
            }
            self.completingTaskIds.remove(task.id)
            self.undoToast = UndoToast(taskId: task.id, title: task.title)
            try? await Task.sleep(for: .seconds(5))
            if self.undoToast?.taskId == task.id { self.undoToast = nil }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            self?.confettiBursts.removeAll { $0.age > 1.2 }
        }
    }

    func undoComplete() {
        guard let toast = undoToast else { return }
        undoToast = nil
        store.setStatus(toast.taskId, .ready)
    }

    /// "Tidy": arrange the current canvas (board or inbox tab) into 4 fixed
    /// columns, one per TaskKind (code, writing, research, other), each
    /// column ordered by priority. Persists explicit positions — a
    /// deliberate grid, not a free reflow.
    func tidyCanvas() {
        let tasks = tab == .inbox ? inboxCanvasTasks() : canvasTasks()
        let columns = TaskKind.allCases // [code, writing, research, other]
        let colWidth = TaskCanvasCard.width + CanvasView.gutter
        var colY = [CGFloat](repeating: CanvasView.topInset, count: columns.count)

        for kind in columns {
            let idx = columns.firstIndex(of: kind)!
            let x = CanvasView.margin + CGFloat(idx) * colWidth
            let inKind = tasks
                .filter { $0.taskKind == kind }
                .sorted { $0.aiPriority < $1.aiPriority }
            for task in inKind {
                store.setCanvasPosition(task.id, x: Double(x), y: Double(colY[idx]))
                colY[idx] += Self.estimatedCardHeight(task) + DS.Space.lg - 4
            }
        }
    }

    /// Deterministic height guess for tidy's grid spacing (no view-tree
    /// height measurement needed — small gaps are an acceptable trade-off).
    private static func estimatedCardHeight(_ task: TaskItem) -> CGFloat {
        var h: CGFloat = 92
        if task.title.count > 40 { h += 20 }
        if !task.stepList.isEmpty { h += 28 }
        return h
    }

    // MARK: - Card actions (FR23)

    func run(_ task: TaskItem) {
        runner.startRun(taskId: task.id)
        selectedTaskId = task.id
    }

    func snooze(_ task: TaskItem, hours: Double = 24) {
        var t = task
        t.status = .snoozed
        t.snoozedUntil = Date().addingTimeInterval(hours * 3600)
        store.update(t)
    }

    func archive(_ task: TaskItem) {
        store.setStatus(task.id, .archived)
    }

    /// Prioritization is manual-only — composition changes no longer trigger
    /// a re-rank (kept as a hook in case scheduled prompts revive it).
    func boardCompositionChanged() {}

    func togglePin(_ task: TaskItem) {
        if task.isPinned {
            store.unpin(task.id)
        } else {
            let minPinned = store.boardTasks().compactMap(\.userPinnedRank).min() ?? 1
            store.pin(task.id, at: minPinned - 1) // pin to top
        }
    }
}
