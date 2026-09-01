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
    /// Dedicated AI-agent management page (create/edit/delete agents).
    @Published var showAgents = false
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

    /// Composio pull state (header button + status line). `pullingSource` is
    /// the single-source pull; "Pull from all" tracks a count instead (it runs
    /// sources in parallel).
    @Published var pullingSource: ComposioIngest.FetchTarget?
    @Published var pullAllRemaining = 0
    @Published var pullStatus: String?

    /// Any pull activity at all — the guard every scheduler/autopilot uses.
    var isPulling: Bool { pullingSource != nil || pullAllRemaining > 0 }

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

    /// AI helper failures this session (F4): enrich/draft/prep degrade to
    /// "no change" by design, but silently — log them so the activity feed
    /// and the footer status line show the misses.
    @Published private(set) var aiFailures: [ActivityEvent] = []

    /// Record an AI failure: always into the activity feed; user-triggered
    /// ones also flash the footer status line (background auto-triage stays
    /// quiet — a toast per failed enrich would be noise).
    func noteAIFailure(_ text: String, toast: Bool = true) {
        aiFailures.append(.init(at: Date(), icon: "exclamationmark.triangle", text: text))
        if toast { showPullStatus(text) }
    }

    /// Canvas completion choreography: tasks mid check-animation (still
    /// rendered), live confetti bursts, and the undo toast.
    @Published var completingTaskIds: Set<UUID> = []
    @Published var confettiBursts: [ConfettiBurst] = []
    @Published var undoToast: UndoToast?
    /// Floating quick-capture card (N key / pill +).
    @Published var showCapture = false
    /// Morning briefing panel (A1) — floats over the board canvas.
    @Published var showBriefing = false
    @Published var briefingBusy = false
    /// Most recently created task — drives the pop-in animation on canvas.
    @Published var lastCreatedTaskId: UUID?

    struct UndoToast: Equatable {
        let taskId: UUID
        let title: String
    }

    let store: TaskStore
    let backendTestSession: BackendTestSession
    private(set) var runner: TaskRunner
    private var ai: TaskAI
    private var ingest: ComposioIngest
    /// Shared last-working-day digests (Granola/Slack/Jira/GitHub) — TTL
    /// cache so prep notes across meetings reuse one fetch per source.
    private(set) var workContext: WorkContext
    private var providerGeneration: UInt
    private var pendingConnectionCompletions:
        [UUID: ([ComposioIngest.Connection]?, String?) -> Void] = [:]
    /// A single-source pull may sequence provider-neutral work after fresh
    /// data arrives (currently the scheduled briefing). Provider replacement
    /// carries these continuations to the new bundle instead of losing them
    /// with the cancelled CLI callback.
    private var pendingPullCompletions: [UUID: () -> Void] = [:]
    private var deferredPullCompletions: [() -> Void] = []

    private struct ProviderToken: Equatable {
        let generation: UInt
        let kind: AskBackendKind
    }

    var dismissHandler: (() -> Void)?
    var settingsHandler: (() -> Void)?
    /// Opens the ask overlay (settings-page footer shortcut).
    var openAskHandler: (() -> Void)?
    /// Wired to notifications — fired when a pull lands new Inbox items
    /// (matters for scheduled pulls with the overlay closed).
    var pullNotifyHandler: ((String) -> Void)?
    /// Wired to notifications — fired when an approved outbound send succeeds.
    var sendNotifyHandler: ((String, UUID) -> Void)?
    /// Wired to notifications — fired when an autopilot draft lands in the
    /// Review queue (gets the "Approve & send" notification actions).
    var draftReadyNotifyHandler: ((String, UUID) -> Void)?
    /// Wired to notifications — fired when the morning briefing is ready;
    /// click-through opens the briefing panel on the board.
    var briefingNotifyHandler: ((String) -> Void)?

    private var lastPrioritized = Date.distantPast
    /// FR42: at most one automatic reflow per 10 minutes.
    private let reflowInterval: TimeInterval = 10 * 60

    var providerKind: AskBackendKind { ai.providerKind }

    init(store: TaskStore, runner: TaskRunner, ai: TaskAI, ingest: ComposioIngest,
         providerGeneration: UInt = 0,
         backendTestSession: BackendTestSession? = nil) {
        self.store = store
        self.backendTestSession = backendTestSession ?? BackendTestSession()
        self.runner = runner
        self.ai = ai
        self.ingest = ingest
        self.workContext = WorkContext(ingest: ingest)
        self.providerGeneration = providerGeneration
    }

    /// The board itself survives an AI-provider switch, but none of its old
    /// asynchronous service callbacks may update the newly selected provider's
    /// state. Invalidating first makes that true even for callbacks already
    /// queued on the main actor.
    func replaceServices(runner: TaskRunner, ai: TaskAI, ingest: ComposioIngest,
                         providerGeneration: UInt) {
        cancelProviderWork(deferPullCompletions: true)
        self.runner = runner
        self.ai = ai
        self.ingest = ingest
        self.workContext = WorkContext(ingest: ingest)
        self.providerGeneration = providerGeneration
        let continuations = deferredPullCompletions
        deferredPullCompletions.removeAll()
        continuations.forEach { $0() }
    }

    /// Invalidate old callbacks immediately while retaining any provider-
    /// neutral work that must resume once replacement services are installed.
    func prepareForProviderReplacement() {
        cancelProviderWork(deferPullCompletions: true)
    }

    func cancelProviderWork() {
        cancelProviderWork(deferPullCompletions: false)
    }

    func cancelSettingsWork() {
        backendTestSession.cancel()
    }

    private func cancelProviderWork(deferPullCompletions: Bool) {
        providerGeneration &+= 1
        ingest.cancel()
        let pendingConnections = Array(pendingConnectionCompletions.values)
        pendingConnectionCompletions.removeAll()
        let pendingPulls = Array(pendingPullCompletions.values)
        pendingPullCompletions.removeAll()
        if deferPullCompletions {
            deferredPullCompletions.append(contentsOf: pendingPulls)
        } else {
            deferredPullCompletions.removeAll()
        }
        pullingSource = nil
        pullAllRemaining = 0
        pullStatus = nil
        decomposeBusy = false
        isPrioritizing = false
        promptBusyTaskIds.removeAll()
        prepBusyTaskIds.removeAll()
        prepPhase = "Gathering context…"
        draftBusyTaskIds.removeAll()
        sendBusyTaskIds.removeAll()
        sendError.removeAll()
        briefingBusy = false
        // Some providers suppress callbacks when cancelled. Settle view-owned
        // spinners synchronously while the old generation is invalidated.
        pendingConnections.forEach { $0(nil, nil) }
    }

    private func providerToken() -> ProviderToken {
        ProviderToken(generation: providerGeneration, kind: providerKind)
    }

    private func isCurrent(_ token: ProviderToken) -> Bool {
        token.generation == providerGeneration && token.kind == providerKind
    }

    /// Settings ▸ Agents passthrough: the selected provider designs a profile.
    func generateAgent(request: String, completion: @escaping (AgentProfile?) -> Void) {
        let token = providerToken()
        let existing = Preferences.shared.agents.map(\.name)
        ai.generateAgent(request: request, existingNames: existing) { g in
            guard self.isCurrent(token) else { return }
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
        let token = providerToken()
        let requestID = UUID()
        pendingConnectionCompletions[requestID] = completion
        ingest.listConnections { [weak self] connections, error in
            guard let self, self.isCurrent(token),
                  let completion = self.pendingConnectionCompletions.removeValue(forKey: requestID)
            else { return }
            completion(connections, error)
        }
    }

    // MARK: - Composio pulls (manual, read-only)

    /// `completion` fires when the pull settles — including the early-outs
    /// (already pulling, no Composio key), so callers sequencing work after a
    /// pull (briefing freshness) are never stranded.
    func pull(_ source: ComposioIngest.Source, completion: (() -> Void)? = nil) {
        pull(.builtin(source), completion: completion)
    }

    func pull(_ target: ComposioIngest.FetchTarget, completion: (() -> Void)? = nil) {
        guard !isPulling, ensureComposioConfigured() else {
            completion?()
            return
        }
        let token = providerToken()
        let completionID = UUID()
        if let completion {
            pendingPullCompletions[completionID] = completion
        }
        pullingSource = target
        pullStatus = nil
        ingest.pull(target, store: store) { [weak self] result in
            guard let self, self.isCurrent(token) else { return }
            let completion = self.pendingPullCompletions.removeValue(forKey: completionID)
            self.pullingSource = nil
            self.showPullStatus(Self.describe(target, result), token: token)
            self.autoTriage(result.createdIds)
            if result.created > 0 {
                self.tab = .inbox
                self.pullNotifyHandler?("\(target.displayName): \(result.created) new task\(result.created == 1 ? "" : "s") in Inbox")
            }
            completion?()
        }
    }

    /// How many sources "Pull from all" runs at once. Each is its own
    /// subprocess; store mutation happens on the main actor either way.
    private static let maxParallelPulls = 3

    /// Pull every enabled target — built-in sources plus toggled-on connected
    /// apps — up to `maxParallelPulls` at a time (each pull is a full
    /// CLI+MCP session, so serial worst-case was minutes × sources), then
    /// show an aggregate status line in the original target order.
    func pullAll() {
        guard !isPulling, ensureComposioConfigured() else { return }
        let token = providerToken()
        pullStatus = nil
        let targets = Preferences.shared.enabledFetchTargets
        guard !targets.isEmpty else {
            showPullStatus("No fetch sources enabled — turn some on in Settings ▸ Connections.")
            return
        }

        var summary = [String?](repeating: nil, count: targets.count)
        var totalCreated = 0
        var nextIndex = 0
        var active = 0
        pullAllRemaining = targets.count

        // All state above mutates on the main actor only — ingest.pull calls
        // its completion on main, so this windowed fan-out has no races.
        func launchMore() {
            while active < Self.maxParallelPulls, nextIndex < targets.count {
                let index = nextIndex
                let target = targets[index]
                nextIndex += 1
                active += 1
                ingest.pull(target, store: store) { [weak self] result in
                    guard let self, self.isCurrent(token) else { return }
                    active -= 1
                    totalCreated += result.created
                    self.autoTriage(result.createdIds)
                    summary[index] = result.error != nil
                        ? "\(target.displayName) ✗"
                        : "\(target.displayName) +\(result.created)"
                    self.pullAllRemaining -= 1
                    if self.pullAllRemaining == 0 {
                        let parts = summary.compactMap { $0 }
                        self.showPullStatus(parts.joined(separator: " · "), token: token)
                        if totalCreated > 0 {
                            self.tab = .inbox
                            self.pullNotifyHandler?("Pull finished: \(totalCreated) new task\(totalCreated == 1 ? "" : "s") in Inbox (\(parts.joined(separator: ", ")))")
                        }
                    } else {
                        launchMore()
                    }
                }
            }
        }
        launchMore()
    }

    private func ensureComposioConfigured() -> Bool {
        if Preferences.shared.composioKey.isEmpty {
            pullStatus = "Set your Composio API key in Settings first."
            return false
        }
        return true
    }

    private static func describe(_ target: ComposioIngest.FetchTarget, _ result: ComposioIngest.Result) -> String {
        if let error = result.error { return "\(target.displayName): \(error)" }
        if result.created == 0 {
            return "\(target.displayName): nothing new"
                + (result.skippedDuplicates > 0 ? " (\(result.skippedDuplicates) already on board)" : "")
        }
        return "\(target.displayName): \(result.created) new in Inbox"
            + (result.skippedDuplicates > 0 ? ", \(result.skippedDuplicates) known" : "")
    }

    private func showPullStatus(_ text: String, token: ProviderToken? = nil) {
        let token = token ?? providerToken()
        pullStatus = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            self.pullStatus = nil
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
        let token = providerToken()
        decomposeBusy = true
        ai.decompose(prompt: text) { [weak self] result in
            guard let self, self.isCurrent(token) else { return }
            self.decomposeBusy = false
            if result == nil {
                self.noteAIFailure("Split into tasks failed. Try again.")
            }
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
    /// The same call doubles as the F6 semantic dedup pass: it sees the open
    /// board and may name an existing task as the same work.
    private func enrich(_ task: TaskItem) {
        enrichBatch([task])
    }

    /// One Haiku call for the whole batch (F5) — auto-triage after a pull
    /// enriches all new items together instead of one call per item.
    private func enrichBatch(_ batch: [TaskItem]) {
        guard !batch.isEmpty else { return }
        let token = providerToken()
        let repoNames = Preferences.shared.repos.map(\.name)
        // Dedup candidates: live tasks, newest first, capped — enough to
        // catch the Jira ticket / Slack thread / meeting action for the same
        // work without bloating a Haiku prompt. Batch members stay in the
        // list so same-pull cross-source dupes are caught too (the self-match
        // guard below stops an item flagging itself).
        let openTasks = store.tasks
            .filter { ![.done, .archived, .cancelled].contains($0.status) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(25)
            .map { "\($0.id.uuidString) — \($0.title.prefix(80))" }
            .joined(separator: "\n")
        // Titles as sent — the apply step's race guard (user renames win).
        let sentTitles = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0.title) })
        let items = batch.map { (id: $0.id, title: $0.title, description: $0.descriptionMD) }
        ai.enrich(items: items, repoNames: repoNames, openTasks: openTasks) { [weak self] results in
            guard let self, self.isCurrent(token) else { return }
            guard let results else {
                // Background auto-triage: feed-only, no toast (see noteAIFailure).
                self.noteAIFailure("Auto-enrich failed — \(batch.count) item\(batch.count == 1 ? "" : "s") left raw", toast: false)
                return
            }
            for e in results {
                guard let id = e.id.flatMap(UUID.init(uuidString:)),
                      let sentTitle = sentTitles[id] else { continue }
                self.applyEnrichment(e, to: id, sentTitle: sentTitle)
            }
        }
    }

    private func applyEnrichment(_ e: TaskAI.Enrichment, to id: UUID, sentTitle: String) {
        guard var t = store.task(id) else { return }
        var filled: [String] = []
        if let title = e.title, !title.isEmpty, title != t.title, t.title == sentTitle {
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
        // F6: flag (never merge) — validate the id points at a real live
        // task so a hallucinated uuid can't wire a dangling dup badge.
        if t.possibleDuplicateOf == nil,
           let dupId = e.duplicateOf.flatMap(UUID.init(uuidString:)),
           dupId != t.id,
           let candidate = store.task(dupId),
           ![.done, .archived, .cancelled].contains(candidate.status) {
            t.possibleDuplicateOf = dupId
        }
        t.aiFilledFields = Array(Set(t.aiFilledFields + filled))
        store.update(t)
    }

    /// Prioritization is MANUAL-ONLY (user decision, overriding FR39's
    /// automatic triggers): it runs solely from the wand button. New tasks
    /// simply land at the bottom until the user asks for a re-rank.
    func schedulePrioritize(force: Bool = false) {
        guard force else { return } // no automatic reflows
        let board = store.boardTasks()
        guard board.count > 1 else { return }
        let token = providerToken()
        lastPrioritized = Date()
        isPrioritizing = true
        ai.prioritize(board: board) { [weak self] entries in
            guard let self, self.isCurrent(token) else { return }
            self.isPrioritizing = false
            guard let entries else {
                self.noteAIFailure("Prioritize failed — board order unchanged. Try again.")
                return
            }
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
        let token = providerToken()
        promptBusyTaskIds.insert(task.id)
        let repoName = Preferences.shared.repos.first { $0.path == task.workspacePath }?.name
        let agent = Preferences.shared.agent(task.agentId)
        ai.handoffPrompt(for: task, repoName: repoName, agent: agent) { [weak self] text in
            guard let self, self.isCurrent(token) else { return }
            self.promptBusyTaskIds.remove(task.id)
            guard let text else {
                self.noteAIFailure("Prompt failed — \(task.title). Try again.")
                return
            }
            guard var t = self.store.task(task.id) else { return }
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
        let token = providerToken()
        prepBusyTaskIds.insert(task.id)
        // Social events (lunch, drinks, birthday…) get logistics-only notes —
        // don't spend four source fetches on work context the notes must not
        // use. The prompt independently guards content for social events the
        // keyword check misses.
        if Self.isSocialEvent(task.title) {
            prepPhase = "Writing notes…"
            writePrepNotes(task, digests: [:], boardContext: "", token: token)
            return
        }
        prepPhase = "Gathering context…"
        let boardContext = boardDigest(excluding: task.id)
        workContext.digests { [weak self] digests in
            guard let self, self.isCurrent(token) else { return }
            self.prepPhase = "Writing notes…"
            self.writePrepNotes(task, digests: digests,
                                boardContext: boardContext, token: token)
        }
    }

    /// Obviously-social calendar events, where prep is logistics, not work.
    static func isSocialEvent(_ title: String) -> Bool {
        let t = title.lowercased()
        let social = ["lunch", "dinner", "breakfast", "coffee", "drinks",
                      "birthday", "party", "picnic", "bbq", "social", "outing",
                      "celebration", "happy hour"]
        return social.contains { t.contains($0) }
    }

    private func writePrepNotes(_ task: TaskItem,
                                digests: [WorkContext.Source: String],
                                boardContext: String,
                                token: ProviderToken) {
        ai.prepNotes(for: task, workDigests: digests,
                     boardContext: boardContext) { [weak self] text in
            guard let self, self.isCurrent(token) else { return }
            self.prepBusyTaskIds.remove(task.id)
            guard let text else {
                self.noteAIFailure("Prep notes failed — \(task.title). Try again.")
                return
            }
            guard var t = self.store.task(task.id) else { return }
            t.prepNotes = text
            self.store.update(t)
        }
    }

    /// Helper draft (reply / writing draft / research brief / approach):
    /// AI writes the type-appropriate helper output; saved on the task so it
    /// survives restarts. Failure = no change.
    func generateHelperDraft(_ task: TaskItem, thenReview: Bool = false) {
        guard !draftBusyTaskIds.contains(task.id) else { return }
        let token = providerToken()
        draftBusyTaskIds.insert(task.id)
        ai.helperDraft(for: task, helper: task.helper) { [weak self] text in
            guard let self, self.isCurrent(token) else { return }
            self.draftBusyTaskIds.remove(task.id)
            guard let text else {
                self.noteAIFailure(thenReview
                    ? "Draft failed — \(task.title). Will retry next launch."
                    : "Draft failed — \(task.title). Try again.")
                return
            }
            guard var t = self.store.task(task.id) else { return }
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
                self.draftReadyNotifyHandler?("Draft ready — \(t.title)", t.id)
            }
        }
    }

    // MARK: - Morning briefing (A1)

    /// Compose the briefing from local data (one `claude -p` call — no
    /// Composio needed) and persist it in Preferences so it survives
    /// relaunch. `notify` = fired by the Autopilot schedule (post the
    /// notification); manual refresh from the panel skips it.
    func generateBriefing(notify: Bool = false) {
        guard !briefingBusy else { return }
        let token = providerToken()
        briefingBusy = true
        ai.morningBriefing(context: briefingContext()) { [weak self] text in
            guard let self, self.isCurrent(token) else { return }
            self.briefingBusy = false
            guard let text else {
                self.noteAIFailure("Morning briefing failed — retry from the ☀️ panel.")
                return
            }
            Preferences.shared.briefingMD = text
            Preferences.shared.briefingGeneratedAt = Date()
            if notify {
                self.briefingNotifyHandler?("Your morning briefing is ready")
            }
        }
    }

    /// Everything the briefing composer needs, from the store alone.
    private func briefingContext() -> String {
        let now = Date()
        let cal = Calendar.current
        var sections: [String] = []

        let stats = store.momentumStats()
        sections.append("Momentum: \(stats.doneToday) done today · current streak \(stats.currentStreak) day\(stats.currentStreak == 1 ? "" : "s") (best \(stats.bestStreak)) · \(stats.totalDone) done all-time")

        // "Overnight" = since yesterday evening; 18h covers a normal workday gap.
        let overnight = store.inboxTasks().filter { $0.createdAt > now.addingTimeInterval(-18 * 3600) }
        if !overnight.isEmpty {
            sections.append("Arrived in Inbox overnight:\n" + overnight.prefix(15).map {
                "- [\($0.source.rawValue)] \($0.title.prefix(90)) — \($0.taskKind.displayName.lowercased())\($0.aiFilledFields.isEmpty ? " (not yet triaged)" : " (auto-triaged)")"
            }.joined(separator: "\n"))
        }

        let review = reviewTasks()
        if !review.isEmpty {
            sections.append("Waiting in Review:\n" + review.prefix(10).map {
                let kind = $0.status == .awaitingPlanApproval ? "plan approval"
                    : ($0.helperDraft != nil ? "draft ready to send" : "run review")
                return "- \($0.title.prefix(90)) — \(kind)"
            }.joined(separator: "\n"))
        }

        let meetings = store.tasks
            .filter {
                $0.source == .calendar
                    && ($0.dueAt.map { cal.isDate($0, inSameDayAs: now) } == true)
                    && ![.done, .archived, .cancelled].contains($0.status)
            }
            .sorted { ($0.dueAt ?? now) < ($1.dueAt ?? now) }
        if !meetings.isEmpty {
            sections.append("Today's meetings:\n" + meetings.map {
                "- \(($0.dueAt ?? now).formatted(date: .omitted, time: .shortened)) \($0.title.prefix(80)) — prep notes \($0.prepNotes?.isEmpty == false ? "ready" : "not written yet")"
            }.joined(separator: "\n"))
        }

        let board = store.boardTasks().prefix(15)
        if !board.isEmpty {
            sections.append("Board (current order):\n" + board.map { t in
                var bits = ["\(t.aiPriority.rawValue) \(t.title.prefix(90))"]
                if let due = t.dueAt { bits.append("due \(due.formatted(.dateTime.month(.abbreviated).day()))") }
                if let e = t.estimate { bits.append("~\(e.rawValue)") }
                if t.isPinned { bits.append("PINNED by me") }
                return "- " + bits.joined(separator: " · ")
            }.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Auto-triage (post-pull)

    /// Enrich freshly-pulled inbox tasks, filling only fields the pull left
    /// empty (enrich never overwrites set values). Gated by autoTriageEnabled;
    /// a failed batch just leaves those tasks raw — no retry loop. Batched
    /// (F5): one Haiku call per chunk instead of one per item; chunks keep
    /// the output JSON comfortably within a single response.
    private func autoTriage(_ ids: [UUID]) {
        guard Preferences.shared.autoTriageEnabled else { return }
        let tasks = ids.compactMap { store.task($0) }
        let chunkSize = 12
        for start in stride(from: 0, to: tasks.count, by: chunkSize) {
            enrichBatch(Array(tasks[start..<min(start + chunkSize, tasks.count)]))
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
        let token = providerToken()
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
            guard let self, self.isCurrent(token) else { return }
            self.sendBusyTaskIds.remove(task.id)
            switch result {
            case .success:
                guard var done = self.store.task(task.id) else { return }
                done.sentAt = Date()
                done.status = .done
                done.completedAt = Date()
                self.store.update(done)
                self.store.record(ApprovalRecord(
                    taskId: task.id, gate: .draft,
                    decision: editedDraft != nil ? .editedThenApproved : .approved,
                    detail: "sent"))
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
        store.record(ApprovalRecord(taskId: task.id, gate: .draft, decision: .approved))
    }

    /// Reject a draft in the review queue → back to Ready, draft kept for
    /// reference. No outbound anything. The reason lands in the audit trail
    /// so rejections teach the system (and the user can see why later).
    func rejectDraft(_ task: TaskItem, reason: String = "") {
        guard var t = store.task(task.id) else { return }
        t.status = .ready
        store.update(t)
        store.record(ApprovalRecord(taskId: task.id, gate: .draft,
                                    decision: .rejected, detail: reason))
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
        // Recently finished — since the start of the last working day, the
        // same window the WorkContext digests cover. A wider window (this was
        // 3 days) feeds a daily standup items already reported at the previous
        // one or two standups.
        let cutoff = Calendar.current.startOfDay(for: WorkContext.lastWorkingDay())
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
            case .draft:
                if a.decision == .rejected {
                    gate = "Draft rejected" + (a.detail.isEmpty ? "" : " — “\(a.detail)”")
                } else {
                    gate = a.detail == "sent" ? "Draft approved & sent" : "Draft approved"
                }
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
        // F4: AI helper failures (session-scoped — enough to debug "why did
        // nothing happen", without persisting transient errors forever).
        events.append(contentsOf: aiFailures)
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
    /// columns, one per TaskKind — Coding, Communication, Research, Other —
    /// each column ordered by the active sort mode (the toolbar dropdown, so
    /// the control the user sees is the control that runs). Persists explicit
    /// positions — a deliberate grid, not a free reflow.
    func tidyCanvas() {
        let tasks = tab == .inbox ? inboxCanvasTasks() : canvasTasks()
        let columns = TaskKind.allCases // [code, writing, research, other]
        let colWidth = TaskCanvasCard.width + CanvasView.gutter
        var colY = [CGFloat](repeating: CanvasView.topInset, count: columns.count)

        for kind in columns {
            let idx = columns.firstIndex(of: kind)!
            let x = CanvasView.margin + CGFloat(idx) * colWidth
            let inKind = tidySorted(tasks.filter { $0.taskKind == kind })
            for task in inKind {
                store.setCanvasPosition(task.id, x: Double(x), y: Double(colY[idx]))
                colY[idx] += Self.estimatedCardHeight(task) + DS.Space.lg - 4
            }
        }
    }

    /// Within-column order for Tidy, matching the toolbar sort dropdown so the
    /// two never disagree. Priority always breaks ties on aiRank; pinned tasks
    /// float to the top of every mode (they're the user's manual override).
    private func tidySorted(_ tasks: [TaskItem]) -> [TaskItem] {
        tasks.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            switch sortMode {
            case .priority:  return (a.aiPriority, a.aiRank) < (b.aiPriority, b.aiRank)
            case .dateAdded: return a.createdAt > b.createdAt
            case .aiRank:    return a.aiRank < b.aiRank
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
