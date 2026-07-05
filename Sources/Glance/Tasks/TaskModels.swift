import Foundation

// PRD V2 §4 — Core Data Model. JSON-persisted for MVP (SQLite deferred; the
// store API is storage-agnostic so the swap doesn't touch callers).

// MARK: - Task (FR20–FR60 backbone)

struct TaskItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var descriptionMD: String = ""
    var status: TaskStatus = .ready
    var labels: [String] = []
    var aiPriority: TaskPriority = .p2
    var aiRank: Int = 0
    var aiRationale: String = ""
    var userPinnedRank: Int?          // non-null = user override; AI never moves (FR41)
    var source: TaskSource = .manual
    var sourceRef: SourceRef?
    var sourceSnapshot: String = ""
    var taskKind: TaskKind = .other
    var workspacePath: String?        // required before a `code` run (FR43)
    var estimate: TaskEstimate?
    var dueAt: Date?
    var snoozedUntil: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var completedAt: Date?
    /// AI-filled field names (FR37 — glyph in UI; user edits win).
    var aiFilledFields: [String] = []
    /// FR33: flagged by the store when a live task looks like the same work.
    var possibleDuplicateOf: UUID?
    /// OQ-V2-3: explicit per-task model override. nil = the assigned agent's
    /// preferred model, else opus (TaskRunner resolves).
    var runModel: String?
    /// Assigned skill profile (AI-routed, user-overridable). nil = generic.
    var agentId: UUID?
    /// AI-written handoff prompt for pasting into an external assistant
    /// (code tasks). User edits win; optional so old JSON decodes.
    var handoffPrompt: String?
    /// Spatial canvas position (top-left, canvas coords). nil = auto-placed
    /// by the flow layout; set only by a user drag. Optional so old JSON decodes.
    var canvasX: Double?
    var canvasY: Double?
    /// Checklist steps. nil = feature unused on this task (old JSON decodes).
    var steps: [TaskStep]?

    var isPinned: Bool { userPinnedRank != nil }
    var isRunnable: Bool { status == .ready || status == .failed }
    var stepList: [TaskStep] { steps ?? [] }
    var stepsDone: Int { stepList.filter(\.done).count }
    var canvasPosition: CGPoint? {
        get {
            guard let x = canvasX, let y = canvasY else { return nil }
            return CGPoint(x: x, y: y)
        }
        set {
            canvasX = newValue.map { Double($0.x) }
            canvasY = newValue.map { Double($0.y) }
        }
    }
}

/// One checklist step on a task (canvas card progress bar + detail editor).
struct TaskStep: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var text: String
    var done: Bool = false
}

enum TaskStatus: String, Codable, CaseIterable {
    case inbox, ready, queued, planning, awaitingPlanApproval = "awaiting_plan_approval"
    case executing, awaitingReview = "awaiting_review"
    case done, failed, blocked, snoozed, archived, cancelled

    /// Statuses shown on the main Board view (FR22).
    static let boardStatuses: Set<TaskStatus> = [
        .ready, .queued, .planning, .awaitingPlanApproval, .executing,
        .awaitingReview, .failed, .blocked
    ]

    var display: String {
        switch self {
        case .inbox: return "Inbox"
        case .ready: return "Ready"
        case .queued: return "Queued"
        case .planning: return "Planning"
        case .awaitingPlanApproval: return "Plan review"
        case .executing: return "Running"
        case .awaitingReview: return "Review"
        case .done: return "Done"
        case .failed: return "Failed"
        case .blocked: return "Blocked"
        case .snoozed: return "Snoozed"
        case .archived: return "Archived"
        case .cancelled: return "Cancelled"
        }
    }
}

enum TaskPriority: String, Codable, CaseIterable, Comparable {
    case p0 = "P0", p1 = "P1", p2 = "P2", p3 = "P3"
    static func < (a: TaskPriority, b: TaskPriority) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

enum TaskSource: String, Codable {
    case manual, prompt, jira, granola, slack, calendar

    var displayName: String {
        switch self {
        case .manual: return "Added by hand"
        case .prompt: return "From a prompt"
        case .jira: return "From Jira"
        case .granola: return "From a meeting"
        case .slack: return "From Slack"
        case .calendar: return "From Calendar"
        }
    }

    var icon: String {
        switch self {
        case .manual: return "square.and.pencil"
        case .prompt: return "text.bubble"
        case .jira: return "ticket"
        case .granola: return "mic"
        case .slack: return "number"
        case .calendar: return "calendar"
        }
    }
}

struct SourceRef: Codable, Equatable {
    var key: String       // Jira key, Slack permalink, Granola meeting id
    var url: String?
}

enum TaskKind: String, Codable, CaseIterable {
    case code, writing, research, other
}

enum TaskEstimate: String, Codable, CaseIterable {
    case minutes, hour, halfday, dayPlus = "day+"
}

// MARK: - Run (§4.2)

struct TaskRun: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var taskId: UUID
    var state: RunState = .planning
    var plan: String = ""
    var planApprovedAt: Date?
    var transcriptPath: String?
    var claudeSessionId: String?
    var workspacePath: String = ""
    var branchName: String?           // code runs: the worktree branch
    var artifacts: [RunArtifact] = []
    var startedAt: Date = Date()
    var endedAt: Date?
    var failureReason: String?
    /// Live progress tail while executing (not persisted verbatim — capped).
    var progressTail: String = ""
}

enum RunState: String, Codable {
    case planning, planRejected = "plan_rejected", executing
    case succeeded, failed, cancelled, timedOut = "timed_out"
    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .timedOut, .planRejected: return true
        case .planning, .executing: return false
        }
    }
}

struct RunArtifact: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var kind: ArtifactKind
    var summary: String
    var payloadRef: String            // path / URL / branch name / text
    var boundary: Bool = false        // true → gated release (FR53)
    var released: Bool = false        // boundary action executed after approval
}

enum ArtifactKind: String, Codable {
    case diff, branch, file, draftText = "draft_text", report, prURL = "pr_url", externalWrite = "external_write"
}

// MARK: - ApprovalRecord (§4.4, append-only audit)

struct ApprovalRecord: Identifiable, Codable {
    var id: UUID = UUID()
    var taskId: UUID
    var runId: UUID?
    var gate: ApprovalGate
    var decision: ApprovalDecision
    var detail: String = ""
    var decidedAt: Date = Date()
}

enum ApprovalGate: String, Codable {
    case plan, review, boundaryAction = "boundary_action", destructiveRefusal = "destructive_refusal", inboxAccept = "inbox_accept"
}

enum ApprovalDecision: String, Codable {
    case approved, rejected, editedThenApproved = "edited_then_approved"
}

// MARK: - IngestionJob (§4.5)

struct IngestionJob: Identifiable, Codable {
    var id: UUID = UUID()
    var source: TaskSource
    var startedAt: Date = Date()
    var endedAt: Date?
    var state: IngestionState = .running
    var tasksCreated: Int = 0
    var tasksSkippedDuplicates: Int = 0
    var error: String?
}

enum IngestionState: String, Codable {
    case running, succeeded, failed, authRequired = "auth_required"
}

// MARK: - Repo registry entry (FR60)

struct RepoEntry: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var path: String
}
