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
        /// Output of a CLI command (/usage…) rather than a model answer;
        /// rendered terminal-style unless it is Markdown.
        var isCommandOutput: Bool = false
        /// The user pressed Stop; the answer is whatever streamed before it.
        var stopped: Bool = false
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

    /// Models the CLI offers (footer menu); empty for providers without a
    /// list (Codex), which keep the plain label.
    @Published var modelOptions: [ModelOption] = []
    /// The chosen `ModelOption.value`; "default" until the user picks one.
    @Published var selectedModel: String = ModelOption.defaultValue
    var modelHandler: ((String) -> Void)?

    /// The footer menu's title: what's answering now, else what's chosen.
    var modelMenuLabel: String {
        if let modelName, !modelName.isEmpty { return modelName }
        return modelOptions.first { $0.value == selectedModel }?.label ?? "Model"
    }

    // MARK: - Permission mode

    /// The CLI's permission mode (footer menu, ⇧Tab). Each conversation
    /// starts in Auto; Bypass only by an explicit menu pick.
    @Published var permissionMode: PermissionMode = .defaultMode
    /// Claude only — Codex has no permission modes.
    @Published var showsPermissionModes = false
    /// A tool use waiting for Allow / Deny; the turn is paused meanwhile.
    @Published var pendingPermission: PermissionRequest?
    var permissionModeHandler: ((PermissionMode) -> Void)?
    var permissionAnswerHandler: ((PermissionRequest, Bool) -> Void)?

    func selectPermissionMode(_ mode: PermissionMode) {
        guard showsPermissionModes, mode != permissionMode else { return }
        permissionMode = mode
        permissionModeHandler?(mode)
    }

    /// ⇧Tab, as in the terminal. False when modes don't apply.
    @discardableResult
    func cyclePermissionMode() -> Bool {
        guard showsPermissionModes else { return false }
        selectPermissionMode(permissionMode.next)
        return true
    }

    func showPermissionRequest(_ request: PermissionRequest) {
        guard isWorking else { return }
        pendingPermission = request
        activity = "Waiting for your approval"
    }

    func answerPermission(allow: Bool) {
        guard let request = pendingPermission else { return }
        pendingPermission = nil
        activity = nil
        permissionAnswerHandler?(request, allow)
    }

    /// Footer menu pick: takes effect from the next message, same conversation.
    func selectModel(_ option: ModelOption) {
        guard option.value != selectedModel else { return }
        selectedModel = option.value
        modelName = option.label
        modelHandler?(option.value)
    }

    /// The provider this overlay talks to (footer name).
    @Published var backendKind: AskBackendKind = .defaultValue

    /// Footer status: "Claude ON" / "Codex OFF". The full `backendLabel`
    /// (with the CLI version) stays for /status.
    var footerStatusLabel: String {
        "\(backendKind.shortName) \(backendConnected ? "ON" : "OFF")"
    }

    /// Footer text: the connection label, plus the model once known.
    var footerLabel: String {
        guard let modelName, !modelName.isEmpty else { return backendLabel }
        return "\(backendLabel) · \(modelName)"
    }

    /// Captured-display label for the context strip, e.g. "Display 1 · 2560×1440".
    @Published var captureLabel: String = ""

    var turnCount: Int { turns.count }
    /// True from submitting a question until its turn completes or fails —
    /// including tool runs between streamed text (FR13 "working" state).
    @Published var isWorking: Bool = false
    /// What the agent is doing right now ("Reading files"), shown with the
    /// working indicator. Nil while it writes answer text.
    @Published var activity: String?

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

    /// The selected CLI is missing or broken: the overlay shows how to fix it
    /// instead of the prompt. Nil when the provider started fine.
    @Published var setupIssue: ProviderSetupIssue?
    var setupRetryHandler: (() -> Void)?
    /// Runs a setup step (install / sign in) in Terminal.
    var setupTerminalHandler: ((String) -> Void)?

    /// Wired by the controller.
    var submitHandler: ((String) -> Void)?
    var dismissHandler: (() -> Void)?
    var settingsHandler: (() -> Void)?
    var historyHandler: ((SessionSummary) -> Void)?
    var clearHandler: (() -> Void)?
    var stopHandler: (() -> Void)?

    var canSubmit: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking
    }

    func submit() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isWorking else { return }
        turns.append(Turn(question: q))
        recordSent(q)
        input = ""
        isWorking = true
        activity = nil
        suggestions = []
        submitHandler?(q)
    }

    /// Stop button: end the turn now and keep its partial answer. The
    /// conversation stays, so the next message continues it.
    func stopTurn() {
        guard isWorking else { return }
        isWorking = false
        activity = nil
        pendingPermission = nil
        if !turns.isEmpty { turns[turns.count - 1].stopped = true }
        stopHandler?()
    }

    /// True once the user stopped the newest turn — its late events are stale.
    var lastTurnStopped: Bool { turns.last?.stopped == true }

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
        activity = nil
        pendingPermission = nil
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
        backendKind = kind
        backendLabel = "Checking \(kind.displayName)…"
        modelName = nil
        setupIssue = nil
        cliCommands = [] // the next provider reports its own (Codex: none)
        terminalOnlyCommands = []
        modelOptions = []
        modelHandler = nil
        permissionMode = .defaultMode
        showsPermissionModes = kind == .claude
        permissionModeHandler = nil
        permissionAnswerHandler = nil
    }

    /// Replace the transcript with a resumed Claude session only if no clear or
    /// provider change occurred while its file was loading.
    @discardableResult
    func loadTranscript(_ pairs: [(question: String, answer: String)],
                        ifGeneration generation: UInt) -> Bool {
        guard generation == transcriptGeneration, showsHistory else { return false }
        turns = pairs.map { Turn(question: $0.question, answer: $0.answer) }
        pairs.forEach { recordSent($0.question) }
        isWorking = false
        activity = nil
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

    // MARK: - Input history (↑ / ↓)

    /// Messages sent from this overlay, oldest first. Kept across Clear, like
    /// a shell's history, so ↑ still recalls them in a fresh conversation.
    private(set) var sentHistory: [String] = []
    /// Position in `sentHistory` while browsing; nil when not browsing.
    private var historyCursor: Int?
    private static let historyLimit = 100

    private func recordSent(_ text: String) {
        historyCursor = nil
        if sentHistory.last == text { return }
        sentHistory.append(text)
        if sentHistory.count > Self.historyLimit {
            sentHistory.removeFirst(sentHistory.count - Self.historyLimit)
        }
    }

    /// Still showing the entry ↑/↓ put there — an edit ends browsing, so the
    /// arrows go back to moving the cursor.
    private var isBrowsingHistory: Bool {
        guard let cursor = historyCursor, sentHistory.indices.contains(cursor) else { return false }
        return input == sentHistory[cursor]
    }

    /// ↑: the previous sent message, newest first. Starts only from an empty
    /// box, so ↑ inside a draft still moves the cursor. False when unhandled.
    @discardableResult
    func recallOlderMessage() -> Bool {
        let next: Int
        if isBrowsingHistory, let cursor = historyCursor {
            next = max(cursor - 1, 0)
        } else if input.isEmpty, !sentHistory.isEmpty {
            next = sentHistory.count - 1
        } else {
            return false
        }
        showHistoryEntry(at: next)
        return true
    }

    /// ↓: back toward the newest message; past it, an empty box again.
    @discardableResult
    func recallNewerMessage() -> Bool {
        guard isBrowsingHistory, let cursor = historyCursor else { return false }
        if cursor + 1 < sentHistory.count {
            showHistoryEntry(at: cursor + 1)
        } else {
            historyCursor = nil
            input = ""
        }
        return true
    }

    private func showHistoryEntry(at index: Int) {
        historyCursor = index
        input = sentHistory[index]
        // A recalled "/status" must not open the `/` menu, or the next ↑ would
        // move the menu instead of going further back.
        slashMenuSuppressed = true
    }

    // MARK: - Backend event application (called on main)

    /// Streamed answer text. The turn stays working — tools may run after it.
    func appendToken(_ text: String) {
        activity = nil
        guard !turns.isEmpty else { return }
        turns[turns.count - 1].answer += text
    }

    /// The agent started a tool run or a thinking block mid-turn.
    func setActivity(_ label: String) {
        guard isWorking else { return }
        activity = label
    }

    /// A CLI command's whole output (see `AskBackendEvent.commandOutput`).
    func appendCommandOutput(_ text: String) {
        isWorking = false
        activity = nil
        pendingPermission = nil
        guard !turns.isEmpty else { return }
        turns[turns.count - 1].answer = text
        turns[turns.count - 1].isCommandOutput = true
    }

    /// The turn couldn't be answered (signed out): drop it and put the
    /// question back in the box to resend once fixed.
    func returnLastQuestionToInput() {
        isWorking = false
        activity = nil
        pendingPermission = nil
        guard let last = turns.popLast() else { return }
        input = last.question
    }

    func completeTurn() {
        isWorking = false
        activity = nil
        pendingPermission = nil
    }

    /// Swap the last answer's text (task-capture cleanup after completion).
    func replaceLastAnswer(_ text: String) {
        guard !turns.isEmpty else { return }
        turns[turns.count - 1].answer = text
    }

    func failTurn(_ message: String) {
        isWorking = false
        activity = nil
        pendingPermission = nil
        guard !turns.isEmpty else { return }
        turns[turns.count - 1].answer = message
        turns[turns.count - 1].failed = true
    }
}
