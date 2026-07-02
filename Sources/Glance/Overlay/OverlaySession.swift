import SwiftUI

/// View-model bridging the overlay UI and the backend for one overlay session
/// (hotkey-press → dismissal). Distinct from the backend's Claude session.
@MainActor
final class OverlaySession: ObservableObject {

    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var answer: String = ""
        var failed: Bool = false
    }

    @Published var input: String = ""
    @Published var turns: [Turn] = []
    /// Whether to attach a screenshot to the next message (toggled in overlay).
    /// Default off — attach only when the user opts in.
    @Published var attachImage: Bool = false

    /// Claude CLI connection state, shown in the overlay footer.
    @Published var backendConnected: Bool = false
    @Published var backendLabel: String = "Checking Claude CLI…"

    /// Captured-display label for the context strip, e.g. "Display 1 · 2560×1440".
    @Published var captureLabel: String = ""

    var turnCount: Int { turns.count }
    /// True between submitting a question and the first streamed token (FR13
    /// "working" state).
    @Published var isWorking: Bool = false

    /// Past Claude CLI sessions for the footer History dropdown.
    @Published var historySessions: [SessionSummary] = []

    /// True rendered height of the overlay content, reported by the view
    /// (GeometryReader). The controller sizes the idle window from this —
    /// AppKit-side measurement of the hosting view proved unreliable and
    /// clipped the content.
    @Published var contentHeight: CGFloat = 0

    /// Wired by the controller.
    var submitHandler: ((String) -> Void)?
    var dismissHandler: (() -> Void)?
    var settingsHandler: (() -> Void)?
    var historyHandler: ((SessionSummary) -> Void)?
    var clearHandler: (() -> Void)?

    var canSubmit: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking
    }

    func submit() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isWorking else { return }
        turns.append(Turn(question: q))
        input = ""
        isWorking = true
        submitHandler?(q)
    }

    /// Wipe the conversation back to the idle prompt (Clear button).
    func clearTranscript() {
        turns = []
        input = ""
        isWorking = false
        attachImage = false
    }

    /// Replace the transcript with a resumed session's past turns (History).
    func loadTranscript(_ pairs: [(question: String, answer: String)]) {
        turns = pairs.map { Turn(question: $0.question, answer: $0.answer) }
        isWorking = false
        input = ""
    }

    // MARK: - Backend event application (called on main)

    func appendToken(_ text: String) {
        isWorking = false
        guard !turns.isEmpty else { return }
        turns[turns.count - 1].answer += text
    }

    func completeTurn() {
        isWorking = false
    }

    func failTurn(_ message: String) {
        isWorking = false
        guard !turns.isEmpty else { return }
        turns[turns.count - 1].answer = message
        turns[turns.count - 1].failed = true
    }
}
