import Foundation
import Combine

/// One conversation in the overlay: its transcript (`session`) and its own
/// CLI process (`lifecycle`). Several stay open at once, so a chat keeps
/// working — and keeps its context — while the user is in another one.
@MainActor
final class OverlayChat: Identifiable {
    let id = UUID()
    let session: OverlaySession
    let lifecycle: AskBackendLifecycle
    var backend: AskBackend? { lifecycle.backend }

    /// The Claude conversation to continue when this chat has no live
    /// process: a resumed past session, or a chat whose idle process was
    /// closed to save memory (`AppCoordinator.maxLiveChats`).
    var resumePoint: ResumePoint?
    /// Shown until the first turn loads (a resumed session's title).
    var placeholderTitle: String?
    /// Last time the user had it open (least recently used is parked first).
    var lastActive = Date()
    /// A background turn finished since the user last looked at it.
    var hasUnseenReply = false
    var observers = Set<AnyCancellable>()

    init(session: OverlaySession? = nil, lifecycle: AskBackendLifecycle? = nil) {
        self.session = session ?? OverlaySession()
        self.lifecycle = lifecycle ?? AskBackendLifecycle()
    }

    var isEmpty: Bool { session.turns.isEmpty && placeholderTitle == nil }

    /// The Claude session this chat is (or was last) talking to.
    var claudeSessionId: String? { resumePoint?.sessionId ?? backend?.resumePoint?.sessionId }

    var title: String {
        if let first = session.turns.first?.question { return ChatListModel.title(from: first) }
        return placeholderTitle ?? "New chat"
    }

    var status: ChatListModel.Status {
        if session.pendingPermission != nil { return .needsApproval }
        if session.isWorking { return .working }
        if hasUnseenReply { return .unseenReply }
        if session.turns.last?.failed == true { return .failed }
        return .idle
    }

    func row(isActive: Bool) -> ChatListModel.Row {
        ChatListModel.Row(id: id, title: title, status: status, isActive: isActive, lastActive: lastActive)
    }
}

/// What the overlay's Chats menu shows: the open conversations, newest first,
/// plus the actions it can take on them (wired by the coordinator).
@MainActor
final class ChatListModel: ObservableObject {
    enum Status: Equatable {
        case idle, working, needsApproval, unseenReply, failed
    }

    struct Row: Identifiable, Equatable {
        let id: UUID
        let title: String
        let status: Status
        let isActive: Bool
        let lastActive: Date
    }

    @Published var rows: [Row] = []

    var newChatHandler: (() -> Void)?
    var selectHandler: ((UUID) -> Void)?
    var closeHandler: ((UUID) -> Void)?

    /// A chat in the background wants a look: badge on the Chats button.
    var backgroundNeedsAttention: Bool {
        rows.contains { !$0.isActive && ($0.status == .needsApproval || $0.status == .unseenReply) }
    }

    /// Chats besides the one on screen.
    var hasOtherChats: Bool { rows.contains { !$0.isActive } }

    func newChat() { newChatHandler?() }
    func select(_ id: UUID) { selectHandler?(id) }
    func close(_ id: UUID) { closeHandler?(id) }

    /// A chat's name: its first message, on one line.
    static func title(from question: String, cap: Int = 60) -> String {
        let line = question.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? question
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > cap ? String(trimmed.prefix(cap)) + "…" : trimmed
    }
}
