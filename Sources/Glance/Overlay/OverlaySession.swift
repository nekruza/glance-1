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

    @Published var input: String = "" {
        didSet {
            guard input != oldValue else { return }
            slashSelection = 0
            slashMenuSuppressed = false
        }
    }
    @Published var turns: [Turn] = []
    /// Whether to attach a screenshot to the next message (toggled in overlay).
    /// Default off — attach only when the user opts in.
    @Published var attachImage: Bool = false

    /// Selected ask-backend connection state, shown in the overlay footer.
    @Published var backendConnected: Bool = false
    @Published var backendLabel: String = "Checking \(AskBackendKind.defaultValue.displayName)…"
    /// Human model name reported by the backend once it answers ("Fable 5.1").
    /// Nil until the first reply of a spawned process.
    @Published var modelName: String?

    /// Footer text: the connection label, plus the model once known.
    var footerLabel: String {
        guard let modelName, !modelName.isEmpty else { return backendLabel }
        return "\(backendLabel) · \(modelName)"
    }

    /// Captured-display label for the context strip, e.g. "Display 1 · 2560×1440".
    @Published var captureLabel: String = ""

    var turnCount: Int { turns.count }
    /// True between submitting a question and the first streamed token (FR13
    /// "working" state).
    @Published var isWorking: Bool = false

    /// Past Claude CLI sessions for the footer History dropdown.
    @Published var historySessions: [SessionSummary] = []
    @Published var showsHistory: Bool = true
    private(set) var transcriptGeneration: UInt = 0

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

    /// Flip the screenshot attachment for the next message. Shared by the
    /// footer photo button and the ⌘J shortcut (OverlayController's key monitor).
    func toggleAttachImage() {
        attachImage.toggle()
    }

    /// Submit a suggestion chip as the next message.
    func submitSuggestion(_ text: String) {
        guard !isWorking else { return }
        input = text
        submit()
    }

    /// Wipe the conversation back to the idle prompt (Clear button).
    func clearTranscript() {
        transcriptGeneration &+= 1
        turns = []
        input = ""
        isWorking = false
        attachImage = false
        suggestions = []
    }

    /// End the visible conversation when its provider changes. A fresh summon
    /// will construct and wire the newly selected backend.
    func resetForBackendChange(to kind: AskBackendKind) {
        dismissHandler?()
        clearTranscript()
        showsHistory = kind == .claude
        historyHandler = nil
        historySessions = []
        backendConnected = false
        backendLabel = "Checking \(kind.displayName)…"
        modelName = nil
        cliCommands = [] // the next provider reports its own (Codex: none)
        terminalOnlyCommands = []
    }

    /// Replace the transcript with a resumed Claude session only if no clear or
    /// provider change occurred while its file was loading.
    @discardableResult
    func loadTranscript(_ pairs: [(question: String, answer: String)],
                        ifGeneration generation: UInt) -> Bool {
        guard generation == transcriptGeneration, showsHistory else { return false }
        turns = pairs.map { Turn(question: $0.question, answer: $0.answer) }
        isWorking = false
        input = ""
        return true
    }

    /// Attach the screenshot preview to the turn that was just submitted.
    func setLastTurnThumbnail(_ image: NSImage?) {
        guard !turns.isEmpty else { return }
        turns[turns.count - 1].thumbnail = image
    }

    // MARK: - Slash commands

    /// The CLI's own commands (built-ins, skills, plugin and user commands),
    /// as reported by the backend. Kept across clears so the menu is instant.
    @Published var cliCommands: [SlashCommand] = []
    /// Commands the CLI only runs in its terminal UI; hidden from the menu.
    @Published var terminalOnlyCommands: [String] = []
    /// Highlighted row in the `/` menu.
    @Published var slashSelection = 0
    /// Esc hid the menu for the current input; any edit brings it back.
    @Published private(set) var slashMenuSuppressed = false

    /// Everything the menu can offer: Glance's local commands + the CLI's.
    var allSlashCommands: [SlashCommand] {
        SlashCommandMatcher.merge(cli: cliCommands, hidden: terminalOnlyCommands)
    }

    /// Menu rows for the current input; empty when the menu is closed.
    var slashMatches: [SlashMatch] {
        guard !slashMenuSuppressed, let query = SlashCommandMatcher.query(in: input) else { return [] }
        return SlashCommandMatcher.match(query, in: allSlashCommands)
    }

    private var selectedSlashCommand: SlashCommand? {
        let matches = slashMatches
        guard matches.indices.contains(slashSelection) else { return matches.first?.command }
        return matches[slashSelection].command
    }

    /// ↑/↓ in the menu, wrapping at the ends.
    func moveSlashSelection(_ delta: Int) {
        let count = slashMatches.count
        guard count > 0 else { return }
        slashSelection = ((slashSelection + delta) % count + count) % count
    }

    /// Tab: fill in the selected name and leave the cursor ready for arguments.
    @discardableResult
    func completeSlash() -> Bool {
        guard let command = selectedSlashCommand else { return false }
        input = "/\(command.name) "
        return true
    }

    /// Return: run the selected command right away, as the CLI does.
    @discardableResult
    func runSelectedSlash() -> Bool {
        guard let command = selectedSlashCommand else { return false }
        input = "/\(command.name)"
        submit()
        return true
    }

    /// Click on a menu row.
    func pickSlash(_ command: SlashCommand) {
        input = "/\(command.name)"
        submit()
    }

    /// Esc: close the menu. False when it wasn't open, so Esc can fall
    /// through to dismissing the overlay.
    @discardableResult
    func dismissSlashMenu() -> Bool {
        guard !slashMatches.isEmpty else { return false }
        slashMenuSuppressed = true
        return true
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
