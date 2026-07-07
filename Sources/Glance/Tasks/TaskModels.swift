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
    /// When an approved outbound write (Slack reply / Jira comment) actually
    /// left the machine. nil until a send succeeds. Optional so old JSON decodes.
    var sentAt: Date?
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
    /// AI-written meeting prep notes (calendar/meeting tasks). User edits
    /// win; optional so old JSON decodes.
    var prepNotes: String?
    /// AI-written helper output for the remaining task types (Slack reply
    /// draft, writing draft, research brief, suggested approach). User edits
    /// win; optional so old JSON decodes.
    var helperDraft: String?
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

// MARK: - Helper action (one per task, routed by type)

/// Every task gets exactly one AI helper action, picked by what the task is:
/// meetings get prep notes, code gets a handoff prompt, Slack asks get a
/// reply draft, writing gets a first draft, research gets a brief, and
/// everything else gets a suggested approach.
enum TaskHelper {
    case prepNotes      // → TaskItem.prepNotes
    case handoffPrompt  // → TaskItem.handoffPrompt
    case reply          // → TaskItem.helperDraft
    case draft          // → TaskItem.helperDraft
    case brief          // → TaskItem.helperDraft
    case approach       // → TaskItem.helperDraft

    var buttonTitle: String {
        switch self {
        case .prepNotes: return "Prep notes"
        case .handoffPrompt: return "Create prompt"
        case .reply: return "Draft reply"
        case .draft: return "Draft it"
        case .brief: return "Research brief"
        case .approach: return "Suggest approach"
        }
    }

    var regenerateTitle: String {
        switch self {
        case .prepNotes: return "Regenerate notes"
        case .handoffPrompt: return "Regenerate prompt"
        case .reply: return "Redraft reply"
        case .draft: return "Redraft"
        case .brief: return "Regenerate brief"
        case .approach: return "Rethink approach"
        }
    }

    var icon: String {
        switch self {
        case .prepNotes: return "note.text.badge.plus"
        case .handoffPrompt: return "wand.and.sparkles"
        case .reply: return "arrowshape.turn.up.left"
        case .draft: return "square.and.pencil"
        case .brief: return "book"
        case .approach: return "signpost.right"
        }
    }

    var sectionTitle: String {
        switch self {
        case .prepNotes: return "Meeting prep"
        case .handoffPrompt: return "Prompt for your AI"
        case .reply: return "Suggested reply"
        case .draft: return "Draft"
        case .brief: return "Research brief"
        case .approach: return "Suggested approach"
        }
    }

    var help: String {
        switch self {
        case .prepNotes:
            return "Fetches your last working day from Granola/Slack/Jira/GitHub and writes grounded prep notes into this task"
        case .handoffPrompt:
            return "AI writes a prompt you can paste into another assistant"
        case .reply:
            return "AI drafts the reply to send back — copy, tweak, paste"
        case .draft:
            return "AI writes a first draft of the deliverable"
        case .brief:
            return "AI outlines key questions, where to look, and next steps"
        case .approach:
            return "AI suggests how to tackle this — a short plan and the first move"
        }
    }
}

extension TaskItem {
    /// Which helper this task gets (first matching rule wins).
    var helper: TaskHelper {
        if source == .calendar || labels.contains("meeting") { return .prepNotes }
        if taskKind == .code { return .handoffPrompt }
        if source == .slack { return .reply }
        if taskKind == .writing { return .draft }
        if taskKind == .research { return .brief }
        return .approach
    }

    /// The single gated outbound write this task could perform on approval,
    /// derived solely from source + sourceRef. nil = nothing to send (plain
    /// Approve only). This is the ONE source of truth for send eligibility —
    /// UI shows "Approve & send" iff this is non-nil.
    var outboundTarget: OutboundTarget? {
        guard let ref = sourceRef, !ref.key.isEmpty else { return nil }
        switch source {
        // Slack ingest may store "channel+ts" as the dedupe key; the url field
        // is the real permalink when present — prefer it as the send target.
        case .slack: return .slackReply(permalink: ref.url ?? ref.key)
        case .jira:  return .jiraComment(issueKey: ref.key)
        default:     return nil
        }
    }
}

/// A gated outbound action the user can approve for one task. Every value
/// embeds the concrete target so `performWrite` can name exactly one action.
enum OutboundTarget: Equatable {
    case slackReply(permalink: String)
    case jiraComment(issueKey: String)
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

    /// User-facing column/chip label. Raw values stay stable for persistence
    /// and agent routing (`.code` gates worktree runs); only the label reads
    /// human. `.writing` presents as "Communication" (emails, Slack, docs,
    /// messages, follow-ups) — the tidy column it feeds.
    var displayName: String {
        switch self {
        case .code: return "Coding"
        case .writing: return "Communication"
        case .research: return "Research"
        case .other: return "Other"
        }
    }
}

enum TaskEstimate: String, Codable, CaseIterable {
    case minutes, hour, halfday, dayPlus = "day+"
}

// MARK: - Run (§4.2)

struct TaskRun: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var taskId: UUID
    /// Agent assigned when the run started — survives later task reassignment
    /// so profile activity history stays accurate. Optional so old JSON decodes.
    var agentId: UUID?
    /// User star rating 1-5 for the outcome. nil = unrated (excluded from
    /// averages, not treated as 0). Optional so old JSON decodes.
    var rating: Int?
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
