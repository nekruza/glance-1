import Foundation

/// Constructs only the provider that the user selected. The concrete adapters
/// are supplied by the app composition root, keeping CLI discovery independent
/// of each adapter's process implementation.
struct AutomationProviderFactory {
    typealias ProviderBuilder = (_ path: String, _ version: String) -> AutomationProvider

    private let makeClaude: ProviderBuilder
    private let makeCodex: ProviderBuilder
    private let claudeStatus: () -> ClaudeLocator.Status
    private let codexStatus: () -> CodexLocator.Status

    init(makeClaude: @escaping ProviderBuilder, makeCodex: @escaping ProviderBuilder,
         claudeStatus: @escaping () -> ClaudeLocator.Status = ClaudeLocator.check,
         codexStatus: @escaping () -> CodexLocator.Status = CodexLocator.check) {
        self.makeClaude = makeClaude
        self.makeCodex = makeCodex
        self.claudeStatus = claudeStatus
        self.codexStatus = codexStatus
    }

    /// Locates exactly the requested CLI, then either builds that provider or
    /// returns its unified availability diagnostic.
    func make(kind: AskBackendKind) -> Result<AutomationProvider, AutomationAvailability> {
        switch kind {
        case .claude:
            let status = Self.availability(from: claudeStatus())
            guard case .available(let path, let version) = status else { return .failure(status) }
            return .success(makeClaude(path, version))
        case .codex:
            let status = Self.availability(from: codexStatus())
            guard case .available(let path, let version) = status else { return .failure(status) }
            return .success(makeCodex(path, version))
        }
    }

    static func unavailableMessage(kind: AskBackendKind, status: AutomationAvailability) -> String {
        switch status {
        case .notFound:
            return "\(kind.displayName) not found. Install it and run `\(kind.rawValue)` to sign in."
        case .unusable(_, let reason):
            return "\(kind.displayName) is unavailable: \(reason)"
        case .available:
            return "\(kind.displayName) is available."
        }
    }

    private static func availability(from status: ClaudeLocator.Status) -> AutomationAvailability {
        switch status {
        case .notFound:
            return .notFound
        case .unusable(let path, let reason):
            return .unusable(path: path, reason: reason)
        case .ok(let path, let version):
            return .available(path: path, version: version)
        }
    }

    private static func availability(from status: CodexLocator.Status) -> AutomationAvailability {
        switch status {
        case .notFound:
            return .notFound
        case .unusable(let path, let reason):
            return .unusable(path: path, reason: reason)
        case .ok(let path, let version):
            return .available(path: path, version: version)
        }
    }
}
