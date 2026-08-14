import Foundation

/// Runs non-interactive Codex CLI prompts behind the shared automation boundary.
final class CodexAutomationProvider: AutomationProvider {
    let descriptor: AutomationProviderDescriptor

    private let binaryPath: String
    private let runner = AutomationOneShotRunner(label: "com.glance.automation.codex")
    private let streamingRunner = AutomationStreamingRunner(label: "com.glance.automation.codex.stream")

    init(binaryPath: String, version: String) {
        self.binaryPath = binaryPath
        descriptor = AutomationProviderDescriptor(kind: .codex, version: version)
    }

    deinit {
        runner.cancelAll()
        streamingRunner.cancelAll()
    }

    @discardableResult
    func runText(_ request: AutomationRequest,
                 onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        // One-shot work includes task planning. Keep it outside a user's
        // checkout and make the Codex policy explicit just as task execution
        // does: read-only filesystem access and no network.
        let workspace = request.workingDirectory ?? FileManager.default.temporaryDirectory
        var arguments = ["exec", "--json", "--skip-git-repo-check",
                         "--sandbox", "read-only",
                         "--approve-for-me",
                         "-c", "sandbox_workspace_write.network_access=false"]
        if let model = Self.codexModel(request.model) {
            arguments += ["--model", model]
        }
        arguments += ["--cd", workspace.path]
        arguments.append("-")

        return runner.run(
            executablePath: binaryPath,
            arguments: arguments,
            standardInput: Data(request.prompt.utf8),
            workingDirectory: workspace,
            timeout: request.timeout,
            launchFailurePrefix: "Couldn't launch Codex CLI",
            decode: Self.decode,
            onEvent: onEvent
        )
    }

    @discardableResult
    func startRun(_ request: AutomationRunRequest,
                  onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        var arguments = ["exec", "--json", "--skip-git-repo-check",
                         "--sandbox", request.sandbox ?? "workspace-write",
                         "--approve-for-me",
                         "-c", "sandbox_workspace_write.network_access=false"]
        if let model = Self.codexModel(request.model) {
            arguments += ["--model", model]
        }
        if let workspace = request.workingDirectory {
            arguments += ["--cd", workspace.path]
        }
        arguments.append("-")

        return streamingRunner.run(
            executablePath: binaryPath,
            arguments: arguments,
            standardInput: Data(request.prompt.utf8),
            workingDirectory: request.workingDirectory,
            timeout: request.timeout,
            launchFailurePrefix: "Couldn't launch Codex CLI",
            decodeLine: Self.decodeRunLine,
            finish: Self.finishRun,
            onEvent: onEvent
        )
    }

    @discardableResult
    func runComposio(_ request: ComposioAutomationRequest, token: String,
                     onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        let endpoint = request.endpoint ?? "https://connect.composio.dev/mcp"
        return runner.run(
            executablePath: binaryPath,
            arguments: [
                "exec", "--json", "--skip-git-repo-check",
                "-c", "mcp_servers.composio.url=\"\(endpoint)\"",
                "-c", "mcp_servers.composio.bearer_token_env_var=\"GLANCE_COMPOSIO_TOKEN\"",
                "-"
            ],
            standardInput: Data(request.prompt.utf8),
            workingDirectory: FileManager.default.temporaryDirectory,
            timeout: request.timeout,
            launchFailurePrefix: "Couldn't launch Codex CLI",
            decode: Self.decodeComposio,
            environment: ["GLANCE_COMPOSIO_TOKEN": token],
            timeoutFailure: { timeout in
                "Composio call timed out (Codex CLI didn't respond within \(max(1, Int(timeout.rounded(.up))))s)."
            },
            onEvent: onEvent
        )
    }

    func cancelAll() {
        runner.cancelAll()
        streamingRunner.cancelAll()
    }

    private static func codexModel(_ model: String?) -> String? {
        guard let model else { return nil }
        let claudeAliases: Set<String> = ["haiku", "sonnet", "opus"]
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return claudeAliases.contains(normalized) ? nil : model
    }

    private static func decodeRunLine(_ line: String) -> [AutomationEvent] {
        guard let event = try? CodexStreamEvent.decode(line), let automationEvent = event.automationEvent else {
            return []
        }
        return [automationEvent]
    }

    private static func finishRun(_ errors: Data, _ status: Int32) -> AutomationEvent {
        guard status == 0 else {
            return .failed(failureMessage(errors,
                fallback: "Codex CLI exited unexpectedly (status \(status))."))
        }
        return .failed(failureMessage(errors, fallback: "Codex CLI exited without a terminal event."))
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

    private static func decodeComposio(_ output: Data, _ errors: Data, _ status: Int32) -> [AutomationEvent] {
        var events: [AutomationEvent] = []
        var terminal: CodexStreamEvent?
        let lines = String(data: output, encoding: .utf8)?.split(whereSeparator: \Character.isNewline) ?? []

        for line in lines {
            guard terminal == nil, let event = try? CodexStreamEvent.decode(String(line)) else { continue }
            if event.isTerminal {
                terminal = event
            } else if let automationEvent = event.automationEvent {
                events.append(automationEvent)
            }
        }

        if case .failed(let message)? = terminal?.automationEvent {
            events.append(.failed("Codex CLI: \(message)"))
            return events
        }
        guard status == 0, terminal?.automationEvent == .completed else {
            events.append(.failed(ComposioIngest.failureMessage(kind: .codex, status: status)))
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
