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

    /// Wired by the controller.
    var submitHandler: ((String) -> Void)?
    var dismissHandler: (() -> Void)?
    var settingsHandler: (() -> Void)?

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
