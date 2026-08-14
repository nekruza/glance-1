import Foundation

/// Builds the conversational backend for the provider selected in Settings.
/// Keeping discovery and construction behind the same selected-kind boundary
/// as task automation lets the app composition root prove that Ask cannot
/// quietly fall back to the other CLI.
struct AskBackendFactory {
    typealias BackendBuilder = (_ path: String) -> AskBackend

    struct Selection {
        let backend: AskBackend
        let version: String
    }

    private let makeClaude: BackendBuilder
    private let makeCodex: BackendBuilder
    private let claudeStatus: () -> ClaudeLocator.Status
    private let codexStatus: () -> CodexLocator.Status

    init(makeClaude: @escaping BackendBuilder = { ClaudeBackend(binaryPath: $0) },
         makeCodex: @escaping BackendBuilder = { CodexBackend(binaryPath: $0) },
         claudeStatus: @escaping () -> ClaudeLocator.Status = ClaudeLocator.check,
         codexStatus: @escaping () -> CodexLocator.Status = CodexLocator.check) {
        self.makeClaude = makeClaude
        self.makeCodex = makeCodex
        self.claudeStatus = claudeStatus
        self.codexStatus = codexStatus
    }

    /// Locates and constructs exactly the selected conversational CLI.
    func make(kind: AskBackendKind) -> Result<Selection, AutomationAvailability> {
        switch kind {
        case .claude:
            let availability = Self.availability(from: claudeStatus())
            guard case .available(let path, let version) = availability else {
                return .failure(availability)
            }
            return .success(Selection(backend: makeClaude(path), version: version))
        case .codex:
            let availability = Self.availability(from: codexStatus())
            guard case .available(let path, let version) = availability else {
                return .failure(availability)
            }
            return .success(Selection(backend: makeCodex(path), version: version))
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
