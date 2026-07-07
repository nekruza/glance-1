import Foundation
import Combine

/// Task persistence + board state (PRD V2 §4). JSON file store for MVP —
/// atomic writes, loaded at launch; API is storage-agnostic so a later SQLite
/// swap doesn't touch callers. All mutation on the main actor.
@MainActor
final class TaskStore: ObservableObject {

    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var runs: [TaskRun] = []
    @Published private(set) var approvals: [ApprovalRecord] = []

    private let dir: URL
    private let fileURL: URL
    private var saveWork: DispatchWorkItem?

    private struct Snapshot: Codable {
        var version = 1
        var tasks: [TaskItem]
        var runs: [TaskRun]
        var approvals: [ApprovalRecord]
    }

    init() {
        dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Glance", isDirectory: true)
        fileURL = dir.appendingPathComponent("tasks.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Queries

    /// Board ordering (FR21): pinned tasks at their pinned positions first,
    /// then AI rank. Snoozed tasks that woke up return automatically.
    func boardTasks() -> [TaskItem] {
        wakeSnoozed()
        let active = tasks.filter { TaskStatus.boardStatuses.contains($0.status) }
        let pinned = active.filter(\.isPinned).sorted { ($0.userPinnedRank ?? 0) < ($1.userPinnedRank ?? 0) }
        let rest = active.filter { !$0.isPinned }.sorted { $0.aiRank < $1.aiRank }
        return pinned + rest
    }

    func inboxTasks() -> [TaskItem] {
        tasks.filter { $0.status == .inbox }.sorted { $0.createdAt > $1.createdAt }
    }

    func doneTasks() -> [TaskItem] {
        tasks.filter { $0.status == .done || $0.status == .archived || $0.status == .cancelled }
            .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
    }

    func task(_ id: UUID) -> TaskItem? { tasks.first { $0.id == id } }

    func runs(for taskId: UUID) -> [TaskRun] {
        runs.filter { $0.taskId == taskId }.sorted { $0.startedAt > $1.startedAt }
    }

    func approvals(for taskId: UUID) -> [ApprovalRecord] {
        approvals.filter { $0.taskId == taskId }.sorted { $0.decidedAt > $1.decidedAt }
    }

    // MARK: - Task mutation

    @discardableResult
    func add(_ task: TaskItem) -> TaskItem {
        var t = task
        // New unpinned tasks land at the bottom of AI order until re-ranked.
        if t.aiRank == 0 { t.aiRank = (tasks.map(\.aiRank).max() ?? 0) + 1 }
        // FR33: flag likely duplicates of live tasks (never auto-merge).
        if let dup = likelyDuplicate(of: t) { t.possibleDuplicateOf = dup.id }
        tasks.append(t)
        persist()
        return t
    }

    // MARK: - Duplicates (FR33)

    /// Word-overlap heuristic against live (non-terminal) tasks.
    private func likelyDuplicate(of task: TaskItem) -> TaskItem? {
        let live = tasks.filter {
            ![.done, .archived, .cancelled].contains($0.status) && $0.id != task.id
        }
        let a = Self.titleWords(task.title)
        guard a.count >= 2 else { return nil }
        for candidate in live {
            let b = Self.titleWords(candidate.title)
            guard b.count >= 2 else { continue }
            let overlap = Double(a.intersection(b).count) / Double(a.union(b).count)
            if overlap >= 0.55 { return candidate }
        }
        return nil
    }

    private static func titleWords(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count > 2 })
    }

    /// Merge `dupId` into `intoId`: union labels, append description, archive
    /// the duplicate. The surviving task keeps its state and runs.
    func mergeDuplicate(_ dupId: UUID, into intoId: UUID) {
        guard var survivor = task(intoId), var dup = task(dupId) else { return }
        for label in dup.labels where !survivor.labels.contains(label) {
            survivor.labels.append(label)
        }
        if !dup.descriptionMD.isEmpty {
            survivor.descriptionMD += "\n\n---\n_Merged from “\(dup.title)” (\(dup.source.rawValue)):_\n\(dup.descriptionMD)"
        }
        update(survivor)
        dup.status = .archived
        dup.possibleDuplicateOf = nil
        update(dup)
    }

    func dismissDuplicateFlag(_ id: UUID) {
        guard var t = task(id) else { return }
        t.possibleDuplicateOf = nil
        update(t)
    }

    func update(_ task: TaskItem) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        var t = task
        t.updatedAt = Date()
        tasks[idx] = t
        persist()
    }

    func setStatus(_ id: UUID, _ status: TaskStatus) {
        guard var t = task(id) else { return }
        t.status = status
        if status == .done { t.completedAt = Date() }
        update(t)
    }

    func delete(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        persist()
    }

    /// Accept an inbox task onto the board (FR34 — the ingestion gate).
    func acceptFromInbox(_ id: UUID) {
        guard var t = task(id), t.status == .inbox else { return }
        t.status = .ready
        update(t)
        record(ApprovalRecord(taskId: id, gate: .inboxAccept, decision: .approved))
    }

    // MARK: - Canvas positions

    /// Persist a card's dragged canvas position. Deliberately does NOT go
    /// through `update()` — drag noise must not bump `updatedAt` (it is the
    /// doneTasks sort fallback) and must not touch enrich fields.
    func setCanvasPosition(_ id: UUID, x: Double?, y: Double?) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].canvasX = x
        tasks[idx].canvasY = y
        persist()
    }

    /// "Tidy" — drop every persisted position so the flow layout re-arranges
    /// all cards by the current sort. One persist for the whole sweep.
    func clearAllCanvasPositions() {
        var changed = false
        for i in tasks.indices where tasks[i].canvasX != nil || tasks[i].canvasY != nil {
            tasks[i].canvasX = nil
            tasks[i].canvasY = nil
            changed = true
        }
        if changed { persist() }
    }

    // MARK: - Momentum (streaks computed from completedAt — no extra state)

    struct MomentumStats: Equatable {
        var doneToday = 0
        var currentStreak = 0    // consecutive days ending today/yesterday with ≥1 completion
        var bestStreak = 0
        var totalDone = 0
    }

    func momentumStats(now: Date = Date(), calendar: Calendar = .current) -> MomentumStats {
        let stamps = tasks.compactMap { $0.status == .cancelled ? nil : $0.completedAt }
        guard !stamps.isEmpty else { return MomentumStats() }
        let days = Set(stamps.map { calendar.startOfDay(for: $0) }).sorted()
        let today = calendar.startOfDay(for: now)

        var stats = MomentumStats()
        stats.totalDone = stamps.count
        stats.doneToday = stamps.filter { calendar.isDate($0, inSameDayAs: now) }.count

        // Best streak: longest run of consecutive days.
        var run = 1
        for i in 1..<days.count {
            let next = calendar.date(byAdding: .day, value: 1, to: days[i - 1])
            run = (days[i] == next) ? run + 1 : 1
            stats.bestStreak = max(stats.bestStreak, run)
        }
        stats.bestStreak = max(stats.bestStreak, 1)

        // Current streak: walk back from today (a yesterday-anchored streak
        // still counts — today just hasn't had a completion yet).
        var cursor = today
        if !days.contains(cursor) {
            guard let y = calendar.date(byAdding: .day, value: -1, to: cursor),
                  days.contains(y) else { return stats }
            cursor = y
        }
        while days.contains(cursor) {
            stats.currentStreak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return stats
    }

    /// Pin a task at a board position (FR41). AI reflows around pins.
    func pin(_ id: UUID, at position: Int) {
        guard var t = task(id) else { return }
        t.userPinnedRank = position
        update(t)
    }

    func unpin(_ id: UUID) {
        guard var t = task(id) else { return }
        t.userPinnedRank = nil
        update(t)
    }

    /// Apply an AI prioritization result (FR39): ordered ids + rationales.
    /// Pinned tasks are never moved (FR41) — their aiRank updates are skipped.
    func applyPrioritization(_ ordered: [(id: UUID, rationale: String, priority: TaskPriority)]) {
        var rank = 1
        for entry in ordered {
            guard let idx = tasks.firstIndex(where: { $0.id == entry.id }) else { continue }
            guard !tasks[idx].isPinned else { continue }
            tasks[idx].aiRank = rank
            tasks[idx].aiRationale = entry.rationale
            tasks[idx].aiPriority = entry.priority
            rank += 1
        }
        persist()
    }

    // MARK: - Runs

    @discardableResult
    func addRun(_ run: TaskRun) -> TaskRun {
        runs.append(run)
        persist()
        return run
    }

    func updateRun(_ run: TaskRun) {
        guard let idx = runs.firstIndex(where: { $0.id == run.id }) else { return }
        runs[idx] = run
        persist()
    }

    func run(_ id: UUID) -> TaskRun? { runs.first { $0.id == id } }

    /// NFR13: mark runs orphaned by a crash/quit as failed, keep transcripts.
    func failOrphanedRuns() {
        for i in runs.indices where !runs[i].state.isTerminal {
            runs[i].state = .failed
            runs[i].failureReason = "Interrupted — app quit while the run was active."
            runs[i].endedAt = Date()
            if var t = task(runs[i].taskId),
               [.executing, .planning, .queued, .awaitingPlanApproval].contains(t.status) {
                t.status = .failed
                update(t)
            }
        }
        persist()
    }

    // MARK: - Audit

    func record(_ approval: ApprovalRecord) {
        approvals.append(approval)
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let snap = try JSONDecoder.glance.decode(Snapshot.self, from: data)
            tasks = snap.tasks
            runs = snap.runs
            approvals = snap.approvals
        } catch {
            // §10 DB corruption: back the file aside, start fresh, tell via log.
            let backup = dir.appendingPathComponent("tasks.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            NSLog("Glance: task store unreadable, backed up to \(backup.path)")
        }
    }

    /// Debounced atomic write.
    private func persist() {
        saveWork?.cancel()
        let snap = Snapshot(tasks: tasks, runs: runs, approvals: approvals)
        let url = fileURL
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder.glance.encode(snap) else { return }
            try? data.write(to: url, options: .atomic)
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Flush synchronously (app quit).
    func flush() {
        saveWork?.cancel()
        let snap = Snapshot(tasks: tasks, runs: runs, approvals: approvals)
        if let data = try? JSONEncoder.glance.encode(snap) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func wakeSnoozed() {
        let now = Date()
        var changed = false
        for i in tasks.indices where tasks[i].status == .snoozed {
            if let until = tasks[i].snoozedUntil, until <= now {
                tasks[i].status = .ready
                tasks[i].snoozedUntil = nil
                changed = true
            }
        }
        if changed { persist() }
    }
}

extension JSONEncoder {
    static var glance: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var glance: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - Agent stats (derived on read — no extra persistence)

/// Headline numbers for an agent's profile card, computed from run history.
struct AgentStats {
    var totalRuns: Int
    /// Percent of succeeded over succeeded+failed. nil until one such run exists.
    var successPercent: Int?
    /// Mean of 1-5 star ratings; unrated runs are excluded, not counted as 0.
    var averageRating: Double?
}

extension TaskStore {

    func stats(forAgent agentId: UUID) -> AgentStats {
        let agentRuns = runs.filter { $0.agentId == agentId }
        let decided = agentRuns.filter { $0.state == .succeeded || $0.state == .failed }
        let ratings = agentRuns.compactMap(\.rating)
        return AgentStats(
            totalRuns: agentRuns.count,
            successPercent: decided.isEmpty ? nil
                : Int((Double(decided.filter { $0.state == .succeeded }.count)
                       / Double(decided.count) * 100).rounded()),
            averageRating: ratings.isEmpty ? nil
                : Double(ratings.reduce(0, +)) / Double(ratings.count)
        )
    }

    /// Newest-first terminal runs for an agent's activity feed.
    func recentRuns(forAgent agentId: UUID, limit: Int = 20) -> [TaskRun] {
        Array(runs.filter { $0.agentId == agentId && $0.state.isTerminal }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(limit))
    }
}
