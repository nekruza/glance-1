import SwiftUI
import AppKit

/// View-model bridging the overlay UI and the backend for one overlay session
/// (hotkey-press → dismissal). Distinct from the backend's Claude session.
@MainActor
final class OverlaySession: ObservableObject {

    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var answer: String = ""
        var failed: Bool = false
        /// Downscaled preview of the screenshot sent with this question, shown
        /// in the asked header. nil for text-only turns.
        var thumbnail: NSImage?
    }

    @Published var input: String = ""
    @Published var turns: [Turn] = []
    /// Whether to attach a screenshot to the next message (toggled in overlay).
    /// Default off — attach only when the user opts in.
    @Published var attachImage: Bool = false

    /// Live meeting-transcription state (footer record button).
    @Published var isTranscribing: Bool = false

    /// Selected ask-backend connection state, shown in the overlay footer.
    @Published var backendConnected: Bool = false
    @Published var backendLabel: String = "Checking \(AskBackendKind.defaultValue.displayName)…"

    /// Captured-display label for the context strip, e.g. "Display 1 · 2560×1440".
    @Published var captureLabel: String = ""

    var turnCount: Int { turns.count }
    /// True between submitting a question and the first streamed token (FR13
    /// "working" state).
    @Published var isWorking: Bool = false

    /// Past Claude CLI sessions for the footer History dropdown.
    @Published var historySessions: [SessionSummary] = []
    @Published var showsHistory: Bool = true

    /// Context-based follow-up prompts, shown as clickable chips after an
    /// answer completes. Clicking one submits it as the next message.
    @Published var suggestions: [String] = []

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
    var transcribeHandler: (() -> Void)?

    var canSubmit: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking
    }

    func submit() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isWorking else { return }
        turns.append(Turn(question: q))
        input = ""
        isWorking = true
        suggestions = []
        submitHandler?(q)
    }

    /// Submit a suggestion chip as the next message.
    func submitSuggestion(_ text: String) {
        guard !isWorking else { return }
        input = text
        submit()
    }

    /// Wipe the conversation back to the idle prompt (Clear button).
    func clearTranscript() {
        turns = []
        input = ""
        isWorking = false
        attachImage = false
        suggestions = []
    }

    /// Replace the transcript with a resumed session's past turns (History).
    func loadTranscript(_ pairs: [(question: String, answer: String)]) {
        turns = pairs.map { Turn(question: $0.question, answer: $0.answer) }
        isWorking = false
        input = ""
    }

    /// Attach the screenshot preview to the turn that was just submitted.
    func setLastTurnThumbnail(_ image: NSImage?) {
        guard !turns.isEmpty else { return }
        turns[turns.count - 1].thumbnail = image
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

    /// Swap the last answer's text (task-capture cleanup after completion).
    func replaceLastAnswer(_ text: String) {
        guard !turns.isEmpty else { return }
        turns[turns.count - 1].answer = text
    }

    func failTurn(_ message: String) {
        isWorking = false
        guard !turns.isEmpty else { return }
        turns[turns.count - 1].answer = message
        turns[turns.count - 1].failed = true
    }
}
