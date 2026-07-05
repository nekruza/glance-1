import SwiftUI

/// View-model for the task board overlay (F1/F2): tab state, quick-add,
/// prompt-decomposition preview, selection, and the AI triggers (enrichment
/// on create, batched re-prioritization).
@MainActor
final class TaskBoardSession: ObservableObject {

    enum Tab: String, CaseIterable {
        // Declaration order = tab order: Inbox (triage) first.
        case inbox = "Inbox", board = "Board", done = "Done", activity = "Activity"
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

    var dismissHandler: (() -> Void)?
    var settingsHandler: (() -> Void)?
    /// Opens the ask overlay (settings-page footer shortcut).
    var openAskHandler: (() -> Void)?
    /// Wired to notifications — fired when a pull lands new Inbox items
    /// (matters for scheduled pulls with the overlay closed).
    var pullNotifyHandler: ((String) -> Void)?

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
        case .board: base = store.boardTasks()
        case .inbox: base = store.inboxTasks()
        case .done:  base = store.doneTasks()
        case .activity: base = [] // activity tab renders its own feed
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
        let task = store.add(TaskItem(title: text, source: .manual))
        lastCreatedTaskId = task.id
        enrich(task)
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

    /// "Tidy": drop all dragged positions → animated reflow by current sort.
    func tidyCanvas() {
        store.clearAllCanvasPositions()
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
