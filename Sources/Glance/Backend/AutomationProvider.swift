import Foundation

/// The models Glance may present for a provider. `automatic` delegates the
/// choice to the selected CLI.
enum AutomationModelChoice: String, CaseIterable, Equatable {
    case automatic
    case haiku
    case sonnet
    case opus
}

struct AutomationProviderDescriptor: Equatable {
    let kind: AskBackendKind
    let version: String
    /// The selected CLI executable. This is optional for test doubles and
    /// unavailable providers, which do not have a process to probe.
    let binaryPath: String?

    init(kind: AskBackendKind, version: String, binaryPath: String? = nil) {
        self.kind = kind
        self.version = version
        self.binaryPath = binaryPath
    }

    var displayName: String { kind.displayName }

    var modelChoices: [AutomationModelChoice] {
        switch kind {
        case .claude:
            return [.automatic, .haiku, .sonnet, .opus]
        case .codex:
            return [.automatic]
        }
    }

    /// Converts a UI model choice to the CLI argument, respecting the
    /// selected provider's supported choices.
    func model(for choice: AutomationModelChoice?) -> String? {
        guard let choice, choice != .automatic, modelChoices.contains(choice) else { return nil }
        return choice.rawValue
    }
}

struct AutomationRequest: Equatable {
    let prompt: String
    let model: String?
    let workingDirectory: URL?
    let timeout: TimeInterval
    let systemPrompt: String?

    init(prompt: String, model: String? = nil, workingDirectory: URL? = nil,
         timeout: TimeInterval = 240, systemPrompt: String? = nil) {
        self.prompt = prompt
        self.model = model
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.systemPrompt = systemPrompt
    }
}

struct ComposioAutomationRequest: Equatable {
    let prompt: String
    let endpoint: String?
    let timeout: TimeInterval

    init(prompt: String, endpoint: String? = nil, timeout: TimeInterval = 240) {
        self.prompt = prompt
        self.endpoint = endpoint
        self.timeout = timeout
    }
}

struct AutomationRunRequest: Equatable {
    let prompt: String
    let model: String?
    let workingDirectory: URL?
    let transcriptURL: URL?
    let allowedTools: [String]
    let disallowedTools: [String]
    let systemPrompt: String?
    let sandbox: String?
    /// TaskRunner's hard cap owns task lifetime. Provider-level timeouts sit
    /// beyond it as a failsafe for callers that do not cancel promptly.
    let timeout: TimeInterval

    init(prompt: String, model: String? = nil, workingDirectory: URL? = nil,
         transcriptURL: URL? = nil, allowedTools: [String] = [],
         disallowedTools: [String] = [], systemPrompt: String? = nil,
         sandbox: String? = nil, timeout: TimeInterval = 60 * 60) {
        self.prompt = prompt
        self.model = model
        self.workingDirectory = workingDirectory
        self.transcriptURL = transcriptURL
        self.allowedTools = allowedTools
        self.disallowedTools = disallowedTools
        self.systemPrompt = systemPrompt
        self.sandbox = sandbox
        self.timeout = timeout
    }
}

enum AutomationEvent: Equatable {
    case text(String)
    case sessionID(String)
    case completed
    case failed(String)
}

final class AutomationCancellation {
    private var onCancel: (() -> Void)?

    init(_ onCancel: @escaping () -> Void = {}) {
        self.onCancel = onCancel
    }

    func cancel() {
        let action = onCancel
        onCancel = nil
        action?()
    }
}

protocol AutomationProvider: AnyObject {
    var descriptor: AutomationProviderDescriptor { get }

    @discardableResult
    func runText(_ request: AutomationRequest,
                 onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation

    @discardableResult
    func startRun(_ request: AutomationRunRequest,
                  onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation

    @discardableResult
    func runComposio(_ request: ComposioAutomationRequest, token: String,
                     onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation

    func cancelAll()
}

enum AutomationAvailability: Error, Equatable {
    case notFound
    case unusable(path: String, reason: String)
    case available(path: String, version: String)
}
