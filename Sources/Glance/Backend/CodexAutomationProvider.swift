import Foundation

/// Runs non-interactive Codex CLI prompts behind the shared automation boundary.
final class CodexAutomationProvider: AutomationProvider {
    let descriptor: AutomationProviderDescriptor

    private let binaryPath: String
    private let runner = AutomationOneShotRunner(label: "com.glance.automation.codex")

    init(binaryPath: String, version: String) {
        self.binaryPath = binaryPath
        descriptor = AutomationProviderDescriptor(kind: .codex, version: version)
    }

    @discardableResult
    func runText(_ request: AutomationRequest,
                 onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        var arguments = ["exec", "--json", "--skip-git-repo-check"]
        if let model = Self.codexModel(request.model) {
            arguments += ["--model", model]
        }
        arguments.append("-")

        return runner.run(
            executablePath: binaryPath,
            arguments: arguments,
            standardInput: Data(request.prompt.utf8),
            workingDirectory: request.workingDirectory,
            timeout: request.timeout,
            launchFailurePrefix: "Couldn't launch Codex CLI",
            decode: Self.decode,
            onEvent: onEvent
        )
    }

    @discardableResult
    func startRun(_ request: AutomationRunRequest,
                  onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        runText(AutomationRequest(prompt: request.prompt, model: request.model,
                                  workingDirectory: request.workingDirectory), onEvent: onEvent)
    }

    @discardableResult
    func runComposio(_ request: ComposioAutomationRequest, token: String,
                     onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        runText(AutomationRequest(prompt: request.prompt, timeout: request.timeout), onEvent: onEvent)
    }

    func cancelAll() {
        runner.cancelAll()
    }

    private static func codexModel(_ model: String?) -> String? {
        guard let model else { return nil }
        let claudeAliases: Set<String> = ["haiku", "sonnet", "opus"]
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return claudeAliases.contains(normalized) ? nil : model
    }

    private static func decode(_ output: Data, _ errors: Data, _ status: Int32) -> [AutomationEvent] {
        var events: [AutomationEvent] = []
        var terminal: AutomationEvent?
        let lines = String(data: output, encoding: .utf8)?.split(whereSeparator: \Character.isNewline) ?? []

        for line in lines {
            guard terminal == nil else { break }
            guard let event = try? CodexStreamEvent.decode(String(line)) else { continue }
            switch event {
            case .completed:
                terminal = .completed
            case .failed(let message):
                terminal = .failed(message)
            default:
                if let automationEvent = event.automationEvent {
                    events.append(automationEvent)
                }
            }
        }

        if case .failed(let message) = terminal {
            events.append(.failed(message))
            return events
        }
        guard status == 0 else {
            events.append(.failed(failureMessage(errors,
                fallback: "Codex CLI exited unexpectedly (status \(status)).")))
            return events
        }
        guard terminal == .completed else {
            events.append(.failed(failureMessage(errors,
                fallback: "Codex CLI exited without a terminal event.")))
            return events
        }
        events.append(.completed)
        return events
    }

    private static func failureMessage(_ errors: Data, fallback: String) -> String {
        let message = String(data: errors, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }
}
