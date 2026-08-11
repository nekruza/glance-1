import XCTest
@testable import Glance

final class AutomationProviderTests: XCTestCase {
    func testCodexOneShotWritesPromptToStdinAndParsesAgentMessage() throws {
        let result = try runFakeProvider(kind: .codex, prompt: "Return JSON")

        XCTAssertEqual(result.arguments, ["exec", "--json", "--skip-git-repo-check", "-"])
        XCTAssertEqual(result.standardInput, "Return JSON")
        XCTAssertEqual(result.events,
                       [.sessionID("thread-1"), .text("{\"ok\":true}"), .completed])
    }

    func testClaudeOneShotKeepsCurrentPromptCommand() throws {
        let result = try runFakeProvider(kind: .claude, prompt: "Return JSON")

        XCTAssertEqual(result.arguments, ["-p", "Return JSON"])
        XCTAssertEqual(result.events, [.text("{\"ok\":true}"), .completed])
    }

    func testCodexOneShotPlacesModelFlagBeforeStdinPlaceholder() throws {
        let result = try runFakeProvider(kind: .codex, prompt: "Return JSON", model: "gpt-test")

        XCTAssertEqual(result.arguments,
                       ["exec", "--json", "--skip-git-repo-check", "--model", "gpt-test", "-"])
    }

    func testClaudeOneShotPlacesModelFlagBeforePrompt() throws {
        let result = try runFakeProvider(kind: .claude, prompt: "Return JSON", model: "sonnet")

        XCTAssertEqual(result.arguments, ["-p", "--model", "sonnet", "Return JSON"])
    }

    func testOneShotCancellationInvalidatesQueuedEvents() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeExecutable(in: fixtureDirectory, script: #"""
        #!/bin/sh
        sleep 0.1
        printf '{"ok":true}'
        """#)
        let provider = ClaudeAutomationProvider(binaryPath: executable.path, version: "test")
        let staleEvent = expectation(description: "cancelled run emits no event")
        staleEvent.isInverted = true

        let cancellation = provider.runText(AutomationRequest(prompt: "Return JSON")) { _ in
            staleEvent.fulfill()
        }
        cancellation.cancel()

        wait(for: [staleEvent], timeout: 0.3)
        provider.cancelAll()
    }

    func testCancelAllFromTextInvalidatesQueuedCompletion() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeExecutable(in: fixtureDirectory, script: #"""
        #!/bin/sh
        printf '{"ok":true}'
        """#)
        let provider = ClaudeAutomationProvider(binaryPath: executable.path, version: "test")
        let textDelivered = expectation(description: "text is delivered")
        let staleCompletion = expectation(description: "queued completion is invalidated")
        staleCompletion.isInverted = true

        provider.runText(AutomationRequest(prompt: "Return JSON")) { event in
            switch event {
            case .text:
                provider.cancelAll()
                textDelivered.fulfill()
            case .completed:
                staleCompletion.fulfill()
            case .sessionID, .failed:
                break
            }
        }

        wait(for: [textDelivered, staleCompletion], timeout: 0.3)
    }

    func testCodexDrainsLargeStdoutAndStderrWithoutDuplicatingTerminalEvent() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeExecutable(in: fixtureDirectory, script: #"""
        #!/bin/sh
        cat >/dev/null
        i=0
        while [ "$i" -lt 3000 ]; do
            printf 'ignored-output-%064d\n' "$i"
            printf 'diagnostic-%064d\n' "$i" >&2
            i=$((i + 1))
        done
        printf '%s\n' '{"type":"thread.started","thread_id":"thread-1"}'
        printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"done"}}'
        printf '%s\n' '{"type":"turn.completed"}'
        printf '%s\n' '{"type":"turn.completed"}'
        """#)
        let provider = CodexAutomationProvider(binaryPath: executable.path, version: "test")
        let terminal = expectation(description: "large-output process completes")
        var events: [AutomationEvent] = []

        provider.runText(AutomationRequest(prompt: "Go", timeout: 3)) { event in
            events.append(event)
            if event == .completed { terminal.fulfill() }
        }

        wait(for: [terminal], timeout: 3)
        XCTAssertEqual(events, [.sessionID("thread-1"), .text("done"), .completed])
        provider.cancelAll()
    }

    func testCodexDescriptorUsesCodexNameAndDefaultModelOnly() {
        let descriptor = AutomationProviderDescriptor(kind: .codex, version: "0.147.0")
        XCTAssertEqual(descriptor.displayName, "Codex CLI")
        XCTAssertEqual(descriptor.modelChoices, [.automatic])
    }

    func testFactoryReportsTheSelectedMissingCLI() {
        XCTAssertEqual(
            AutomationProviderFactory.unavailableMessage(kind: .codex, status: .notFound),
            "Codex CLI not found. Install it and run `codex` to sign in."
        )
    }

    func testDescriptorMapsOnlySupportedNamedModels() {
        let descriptor = AutomationProviderDescriptor(kind: .codex, version: "0.147.0")

        XCTAssertNil(descriptor.model(for: .automatic))
        XCTAssertNil(descriptor.model(for: .sonnet))
    }

    func testCancellationRunsItsActionOnlyOnce() {
        var cancelCount = 0
        let cancellation = AutomationCancellation { cancelCount += 1 }

        cancellation.cancel()
        cancellation.cancel()

        XCTAssertEqual(cancelCount, 1)
    }

    func testCancellationDoesNotReenterItsAction() {
        var cancelCount = 0
        var shouldReenter = true
        var cancellation: AutomationCancellation?
        cancellation = AutomationCancellation {
            cancelCount += 1
            if shouldReenter {
                shouldReenter = false
                cancellation?.cancel()
            }
        }

        cancellation?.cancel()

        XCTAssertEqual(cancelCount, 1)
    }

    func testFactoryBuildsOnlyTheSelectedProvider() {
        var claudeBuildCount = 0
        var codexBuildCount = 0
        let factory = AutomationProviderFactory(
            makeClaude: { _, _ in
                claudeBuildCount += 1
                return AutomationProviderSpy(kind: .claude)
            },
            makeCodex: { _, _ in
                codexBuildCount += 1
                return AutomationProviderSpy(kind: .codex)
            },
            claudeStatus: {
                XCTFail("Claude locator must not run while Codex is selected")
                return .notFound
            },
            codexStatus: { .ok(path: "/fake/codex", version: "0.147.0") }
        )

        let result = factory.make(kind: .codex)

        guard case .success(let provider) = result else {
            return XCTFail("Expected the available selected provider")
        }
        XCTAssertEqual(provider.descriptor.kind, .codex)
        XCTAssertEqual(claudeBuildCount, 0)
        XCTAssertEqual(codexBuildCount, 1)
    }

    private func runFakeProvider(kind: AskBackendKind, prompt: String,
                                 model: String? = nil) throws -> FakeInvocation {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let script: String
        switch kind {
        case .codex:
            script = #"""
            #!/bin/sh
            fixture_dir="$(dirname "$0")"
            printf '%s\n' "$@" > "$fixture_dir/arguments"
            cat > "$fixture_dir/stdin"
            printf '%s\n' '{"type":"thread.started","thread_id":"thread-1"}'
            printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"{\"ok\":true}"}}'
            printf '%s\n' '{"type":"turn.completed","usage":{}}'
            """#
        case .claude:
            script = #"""
            #!/bin/sh
            fixture_dir="$(dirname "$0")"
            printf '%s\n' "$@" > "$fixture_dir/arguments"
            cat > "$fixture_dir/stdin"
            printf '{"ok":true}'
            """#
        }
        let executable = try makeExecutable(in: fixtureDirectory, script: script)
        let terminal = expectation(description: "provider reaches one terminal event")
        var events: [AutomationEvent] = []
        let factory = AutomationProviderFactory(
            claudeStatus: {
                guard kind == .claude else {
                    XCTFail("Unselected Claude locator must not run")
                    return .notFound
                }
                return .ok(path: executable.path, version: "test")
            },
            codexStatus: {
                guard kind == .codex else {
                    XCTFail("Unselected Codex locator must not run")
                    return .notFound
                }
                return .ok(path: executable.path, version: "test")
            }
        )
        guard case .success(let provider) = factory.make(kind: kind) else {
            throw FakeProviderError.providerUnavailable
        }
        let cancellation = provider.runText(AutomationRequest(prompt: prompt, model: model)) { event in
            events.append(event)
            switch event {
            case .completed, .failed:
                terminal.fulfill()
            case .text, .sessionID:
                break
            }
        }

        wait(for: [terminal], timeout: 2)
        cancellation.cancel()
        provider.cancelAll()
        let arguments = try String(contentsOf: fixtureDirectory.appendingPathComponent("arguments"),
                                   encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let standardInput = try String(contentsOf: fixtureDirectory.appendingPathComponent("stdin"),
                                       encoding: .utf8)
        return FakeInvocation(arguments: arguments, standardInput: standardInput,
                              environment: [:], events: events)
    }

    private func makeFixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("automation-provider-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeExecutable(in directory: URL, script: String) throws -> URL {
        let executable = directory.appendingPathComponent("fake-provider")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: executable.path)
        return executable
    }
}

private struct FakeInvocation {
    let arguments: [String]
    let standardInput: String
    let environment: [String: String]
    let events: [AutomationEvent]
}

private enum FakeProviderError: Error {
    case providerUnavailable
}

final class AutomationProviderSpy: AutomationProvider {
    let descriptor: AutomationProviderDescriptor
    private(set) var requests: [AutomationRequest] = []
    private(set) var cancelAllCount = 0
    var finalText: String

    init(kind: AskBackendKind, finalText: String = "") {
        descriptor = AutomationProviderDescriptor(kind: kind, version: "test")
        self.finalText = finalText
    }

    func runText(_ request: AutomationRequest,
                 onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        requests.append(request)
        if !finalText.isEmpty { onEvent(.text(finalText)) }
        onEvent(.completed)
        return AutomationCancellation()
    }

    func startRun(_ request: AutomationRunRequest,
                  onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        runText(AutomationRequest(prompt: request.prompt, model: request.model), onEvent: onEvent)
    }

    func runComposio(_ request: ComposioAutomationRequest, token: String,
                     onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        runText(AutomationRequest(prompt: request.prompt), onEvent: onEvent)
    }

    func cancelAll() { cancelAllCount += 1 }
}
