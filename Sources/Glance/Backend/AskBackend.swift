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
}

protocol AskBackend: AnyObject {
    var firstTokenTimeout: TimeInterval { get set }
    func configure(systemPrompt: String)
    func startWarm()
    func ask(question: String, imagePNG: Data?, onEvent: @escaping (AskBackendEvent) -> Void)
    func shutdown()
}

extension AskBackend {
    /// Backends that do not expose a distinct instruction channel may ignore
    /// this. First-party implementations install it before warming.
    func configure(systemPrompt: String) {}
}
