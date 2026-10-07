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
}

protocol AskBackend: AnyObject {
    var firstTokenTimeout: TimeInterval { get set }
    func configure(systemPrompt: String)
    func startWarm()
    func ask(question: String, imagePNG: Data?, onEvent: @escaping (AskBackendEvent) -> Void)
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
}
