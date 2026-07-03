import SwiftUI

/// View-model for the task board overlay (F1/F2): tab state, quick-add,
/// prompt-decomposition preview, selection, and the AI triggers (enrichment
/// on create, batched re-prioritization).
@MainActor
final class TaskBoardSession: ObservableObject {

    enum Tab: String, CaseIterable {
        case board = "Board", inbox = "Inbox", done = "Done"
    }

    @Published var tab: Tab = .board
    @Published var quickAdd: String = ""
    @Published var searchText: String = ""
    @Published var selectedTaskId: UUID?
    @Published var isPrioritizing = false

    /// Prompt→tasks flow (FR27): text in, preview list out, user confirms.
    @Published var decomposeMode = false
    @Published var decomposeText = ""
    @Published var decomposeBusy = false
    @Published var decomposePreview: [TaskAI.DecomposedTask] = []
    @Published var decomposeKeep: Set<Int> = []

    let store: TaskStore
    let runner: TaskRunner
    private let ai: TaskAI

    var dismissHandler: (() -> Void)?
    var settingsHandler: (() -> Void)?

    private var lastPrioritized = Date.distantPast
    /// FR42: at most one automatic reflow per 10 minutes.
    private let reflowInterval: TimeInterval = 10 * 60

    init(store: TaskStore, runner: TaskRunner, ai: TaskAI) {
        self.store = store
        self.runner = runner
        self.ai = ai
    }

    // MARK: - Lists

    func visibleTasks() -> [TaskItem] {
        let base: [TaskItem]
        switch tab {
        case .board: base = store.boardTasks()
        case .inbox: base = store.inboxTasks()
        case .done:  base = store.doneTasks()
        }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.title.lowercased().contains(q)
                || $0.labels.contains { $0.lowercased().contains(q) }
                || $0.descriptionMD.lowercased().contains(q)
        }
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
        enrich(task)
        schedulePrioritize()
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
            t.aiFilledFields = ["description", "labels", "taskKind", "estimate"]
            store.add(t)
        }
        decomposeMode = false
        decomposePreview = []
        schedulePrioritize(force: true)
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
            t.aiFilledFields = Array(Set(t.aiFilledFields + filled))
            self.store.update(t)
        }
    }

    /// FR39/FR42: re-prioritize, batched unless forced.
    func schedulePrioritize(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPrioritized) > reflowInterval else { return }
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

    func togglePin(_ task: TaskItem) {
        if task.isPinned {
            store.unpin(task.id)
        } else {
            let minPinned = store.boardTasks().compactMap(\.userPinnedRank).min() ?? 1
            store.pin(task.id, at: minPinned - 1) // pin to top
        }
    }
}
