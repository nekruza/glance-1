import Foundation

enum AskBackendKind: String, CaseIterable, Hashable, Codable {
    case claude
    case codex

    static let defaultValue: AskBackendKind = .claude

    var displayName: String {
        switch self {
        case .claude: return "Claude CLI"
        case .codex: return "Codex CLI"
        }
    }
}

enum AskBackendEvent {
    case token(String)
    case completed
    case failed(String)
    /// The model id the CLI reports on its `system/init` line, e.g.
    /// "claude-fable-5-1". Informational; arrives once per spawned process.
    case model(String)
    /// The whole output of a CLI-local command (/usage, /context, /model…),
    /// which arrives as one result instead of streamed tokens and is laid out
    /// for a terminal rather than written as Markdown.
    case commandOutput(String)
    /// The CLI refused because it isn't signed in. Ends the turn, like
    /// `.failed`, but the overlay offers a Sign in step instead of an error.
    case signedOut
    /// What the agent is doing right now between answer text — a tool run
    /// ("Reading files") or a thinking block. Informational; the turn goes on.
    case activity(String)
}

protocol AskBackend: AnyObject {
    var firstTokenTimeout: TimeInterval { get set }
    func configure(systemPrompt: String)
    func startWarm()
    func ask(question: String, imagePNG: Data?, onEvent: @escaping (AskBackendEvent) -> Void)
    /// Stop the turn in flight (the overlay's Stop button) but keep the
    /// conversation, like Esc in the terminal. The stopped turn's handler gets
    /// no further events; the next `ask` continues the same session.
    func interrupt()
    /// Use this model (a `ModelOption.value`; "default" = the CLI's choice)
    /// from the next message on. Call before `startWarm()` for a new backend;
    /// on a live one it switches the running session, keeping the conversation.
    func setModel(_ value: String)
    func shutdown()
    /// Receives the slash-command catalog (and account) whenever the backend
    /// learns or refreshes it; delivered on main. Register before `startWarm()`.
    func onCatalog(_ handler: @escaping (BackendCatalog) -> Void)
}

extension AskBackend {
    /// Backends that do not expose a distinct instruction channel may ignore
    /// this. First-party implementations install it before warming.
    func configure(systemPrompt: String) {}
    /// Backends without a command catalog never call back.
    func onCatalog(_ handler: @escaping (BackendCatalog) -> Void) {}
    /// Backends that can't stop a turn let it finish; the overlay already
    /// ignores the stopped turn's events.
    func interrupt() {}
    /// Backends without a model list keep their CLI's default.
    func setModel(_ value: String) {}
}
