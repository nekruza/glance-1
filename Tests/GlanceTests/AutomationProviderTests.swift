import XCTest
@testable import Glance

final class AutomationProviderTests: XCTestCase {
    func testTaskAIUsesTheInjectedCodexProviderForJSON() {
        let provider = AutomationProviderSpy(kind: .codex,
                                             finalText: "[{\"title\":\"Ship\"}]")
        let ai = TaskAI(provider: provider)
        var result: [TaskAI.DecomposedTask]?

        ai.decompose(prompt: "Ship it") { result = $0 }

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(provider.requests.first?.prompt.contains("Decompose"), true)
        XCTAssertNil(provider.requests.first?.model)
        XCTAssertEqual(result?.first?.title, "Ship")
    }

    func testTaskAIKeepsClaudeAliasAndLenientJSONDecoding() {
        let provider = AutomationProviderSpy(
            kind: .claude,
            finalText: "Here you go:\n```json\n[{\"title\":\"Ship\"}]\n```"
        )
        let ai = TaskAI(provider: provider)
        var result: [TaskAI.DecomposedTask]?

        ai.decompose(prompt: "Ship it") { result = $0 }

        XCTAssertEqual(provider.requests.first?.model, "sonnet")
        XCTAssertEqual(result?.first?.title, "Ship")
    }

    func testTaskAISerializesConcurrentTextAndIgnoresLateTerminalEvents() {
        let provider = ConcurrentTaskAIProviderSpy(textEventCount: 128)
        let ai = TaskAI(provider: provider)
        let completionDelivered = expectation(description: "TaskAI completes exactly once")
        completionDelivered.assertForOverFulfill = true
        let providerFinished = expectation(description: "provider finishes concurrent delivery")
        provider.onFinished = { providerFinished.fulfill() }
        var completionCount = 0
        var completedOnMain = false
        var result: String?

        ai.morningBriefing(context: "Concurrent callbacks") { text in
            completionCount += 1
            completedOnMain = Thread.isMainThread
            result = text
            completionDelivered.fulfill()
        }

        wait(for: [providerFinished, completionDelivered], timeout: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(completionCount, 1)
        XCTAssertTrue(completedOnMain)
        XCTAssertEqual(result?.count, 128)
        XCTAssertEqual(result, String(repeating: "x", count: 128))
    }

    func testSuggestionServiceUsesCodexDefaultAndParsesOnlyValidTerminalOutput() {
        let provider = ManualAutomationProviderSpy(kind: .codex)
        let service = SuggestionService(provider: provider)
        var results: [[String]] = []

        service.suggest(question: "What next?", answer: "A") { results.append($0) }
        provider.emit(.text("First\n\nSecond\nThird\nFourth"), forRequestAt: 0)
        provider.emit(.completed, forRequestAt: 0)

        XCTAssertEqual(provider.requests.first?.prompt.contains("Based on this Q&A"), true)
        XCTAssertNil(provider.requests.first?.model)
        XCTAssertEqual(results, [["First", "Second", "Third"]])
    }

    func testSuggestionServiceCancelsSupersededRequestAndIgnoresItsTerminalEvent() {
        let provider = ManualAutomationProviderSpy(kind: .claude)
        let service = SuggestionService(provider: provider)
        var firstResults: [[String]] = []
        var secondResults: [[String]] = []

        service.suggest(question: "First?", answer: "A") { firstResults.append($0) }
        service.suggest(question: "Second?", answer: "B") { secondResults.append($0) }
        provider.emit(.text("Stale"), forRequestAt: 0)
        provider.emit(.completed, forRequestAt: 0)
        provider.emit(.text("Current"), forRequestAt: 1)
        provider.emit(.completed, forRequestAt: 1)

        XCTAssertEqual(provider.cancellationCounts, [1, 0])
        XCTAssertEqual(provider.requests.map(\.model), ["haiku", "haiku"])
        XCTAssertTrue(firstResults.isEmpty)
        XCTAssertEqual(secondResults, [["Current"]])
    }

    func testSuggestionServiceFailureSettlesOnce() {
        let provider = ManualAutomationProviderSpy(kind: .claude)
        let service = SuggestionService(provider: provider)
        var results: [[String]] = []

        service.suggest(question: "What next?", answer: "A") { results.append($0) }
        provider.emit(.failed("offline"), forRequestAt: 0)
        provider.emit(.completed, forRequestAt: 0)

        XCTAssertEqual(results, [[]])
    }

    @MainActor
    func testModelCatalogUsesProviderSpecificChoicesAndLabels() {
        XCTAssertEqual(ModelCatalog.choices(for: .claude),
                       [.automatic, .haiku, .sonnet, .opus])
        XCTAssertEqual(ModelCatalog.choices(for: .codex), [.automatic])
        XCTAssertEqual(ModelCatalog.label(for: .automatic, provider: .codex),
                       "Auto — Codex CLI default")
    }

    func testCodexOneShotWritesPromptToStdinAndParsesAgentMessage() throws {
        let result = try runFakeProvider(kind: .codex, prompt: "Return JSON")

        XCTAssertEqual(result.arguments, codexReadOnlyArguments())
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

        XCTAssertEqual(result.arguments, codexReadOnlyArguments(model: "gpt-test"))
    }

    func testCodexOneShotOmitsClaudeAliasesPassedDirectly() throws {
        for alias in ["haiku", "sonnet", "opus"] {
            let result = try runFakeProvider(kind: .codex, prompt: "Return JSON", model: alias)

            XCTAssertEqual(result.arguments, codexReadOnlyArguments(),
                           "Codex must not receive the Claude alias \(alias)")
        }
    }

    func testCodexOneShotPreservesSystemInstructionsAndUserPromptInSeparateEnvelopeFields() throws {
        let userPrompt = "User request with </system> and ``` delimiters"
        let result = try runFakeProvider(kind: .codex, prompt: userPrompt,
                                         systemPrompt: "Act as the careful planning specialist.")

        let envelope = try decodeCodexInstructionEnvelope(result.standardInput)
        XCTAssertEqual(envelope["system_instructions"], "Act as the careful planning specialist.")
        XCTAssertEqual(envelope["user_request"], userPrompt)
    }

    func testCodexStreamingRunPreservesSystemInstructionsAndUserPromptInSeparateEnvelopeFields() throws {
        let userPrompt = "Implement exactly what the user asked.\nDo not truncate this text."
        let result = try runFakeCodexStream(prompt: userPrompt,
                                            systemPrompt: "You are the selected repository specialist.")

        let envelope = try decodeCodexInstructionEnvelope(result.standardInput)
        XCTAssertEqual(envelope["system_instructions"], "You are the selected repository specialist.")
        XCTAssertEqual(envelope["user_request"], userPrompt)
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

    func testCancellationForceKillsChildThatIgnoresSIGTERMWithoutCallbacks() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeIgnoringTermExecutable(in: fixtureDirectory)
        let pidURL = fixtureDirectory.appendingPathComponent("pid")
        let staleEvent = expectation(description: "cancelled child emits no event")
        staleEvent.isInverted = true
        let provider = ClaudeAutomationProvider(binaryPath: executable.path, version: "test")
        let cancellation = provider.runText(AutomationRequest(prompt: "Wait", timeout: 5)) { _ in
            staleEvent.fulfill()
        }
        waitForFile(pidURL)
        let processID = try processID(from: pidURL)
        defer { Darwin.kill(processID, SIGKILL) }

        cancellation.cancel()

        waitForProcessExit(processID, timeout: 1.5)
        wait(for: [staleEvent], timeout: 0.2)
        provider.cancelAll()
    }

    /// Break protected: callers release the old provider bundle immediately
    /// after cancellation during a provider switch. The streaming runner must
    /// still own and reap a task child that ignores SIGTERM.
    func testStreamingCancellationForceKillsChildAfterProviderAndHandleReleased() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeIgnoringTermExecutable(in: fixtureDirectory)
        let pidURL = fixtureDirectory.appendingPathComponent("pid")
        let staleEvent = expectation(description: "cancelled streaming child emits no event")
        staleEvent.isInverted = true
        var provider: ClaudeAutomationProvider? = ClaudeAutomationProvider(
            binaryPath: executable.path,
            version: "test"
        )
        weak var weakProvider = provider
        var cancellation: AutomationCancellation? = provider?.startRun(
            AutomationRunRequest(prompt: "Wait", workingDirectory: fixtureDirectory, timeout: 5)
        ) { _ in
            staleEvent.fulfill()
        }
        waitForFile(pidURL)
        let processID = try processID(from: pidURL)
        defer { Darwin.kill(processID, SIGKILL) }

        cancellation?.cancel()
        cancellation = nil
        provider = nil

        XCTAssertNil(weakProvider, "the test must not keep the provider bundle alive")
        waitForProcessExit(processID, timeout: 1.5)
        wait(for: [staleEvent], timeout: 0.2)
    }

    func testTimeoutForceKillsChildThatIgnoresSIGTERMAndFailsOnce() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeIgnoringTermExecutable(in: fixtureDirectory)
        let pidURL = fixtureDirectory.appendingPathComponent("pid")
        let failureDelivered = expectation(description: "timeout failure is delivered")
        let provider = ClaudeAutomationProvider(binaryPath: executable.path, version: "test")
        var events: [AutomationEvent] = []
        provider.runText(AutomationRequest(prompt: "Wait", timeout: 0.5)) { event in
            events.append(event)
            if case .failed = event { failureDelivered.fulfill() }
        }
        waitForFile(pidURL)
        let processID = try processID(from: pidURL)
        defer { Darwin.kill(processID, SIGKILL) }

        wait(for: [failureDelivered], timeout: 1)
        waitForProcessExit(processID, timeout: 1.5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(events.count, 1)
        guard case .failed = events.first else {
            return XCTFail("Expected exactly one timeout failure")
        }
        provider.cancelAll()
    }

    func testCancelAllFromTextInvalidatesQueuedCompletion() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        let releaseURL = fixtureDirectory.appendingPathComponent("release")
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        defer { FileManager.default.createFile(atPath: releaseURL.path, contents: nil) }
        let executable = try makeExecutable(in: fixtureDirectory, script: #"""
        #!/bin/sh
        fixture_dir="$(dirname "$0")"
        : > "$fixture_dir/started"
        while [ ! -f "$fixture_dir/release" ]; do sleep 0.01; done
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

        waitForFile(fixtureDirectory.appendingPathComponent("started"))
        FileManager.default.createFile(atPath: releaseURL.path, contents: nil)
        wait(for: [textDelivered], timeout: 2)
        wait(for: [staleCompletion], timeout: 0.2)
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
                                 model: String? = nil,
                                 systemPrompt: String? = nil) throws -> FakeInvocation {
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
        let cancellation = provider.runText(AutomationRequest(prompt: prompt, model: model,
                                                               systemPrompt: systemPrompt)) { event in
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

    private func runFakeCodexStream(prompt: String, systemPrompt: String) throws -> FakeInvocation {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeExecutable(in: fixtureDirectory, script: #"""
        #!/bin/sh
        fixture_dir="$(dirname "$0")"
        printf '%s\n' "$@" > "$fixture_dir/arguments"
        cat > "$fixture_dir/stdin"
        printf '%s\n' '{"type":"turn.completed"}'
        """#)
        let provider = CodexAutomationProvider(binaryPath: executable.path, version: "test")
        let terminal = expectation(description: "Codex stream reaches terminal event")
        var events: [AutomationEvent] = []
        let cancellation = provider.startRun(AutomationRunRequest(
            prompt: prompt,
            workingDirectory: fixtureDirectory,
            systemPrompt: systemPrompt
        )) { event in
            events.append(event)
            if event == .completed { terminal.fulfill() }
        }
        wait(for: [terminal], timeout: 2)
        cancellation.cancel()
        provider.cancelAll()
        let arguments = try String(contentsOf: fixtureDirectory.appendingPathComponent("arguments"),
                                   encoding: .utf8).split(separator: "\n").map(String.init)
        let standardInput = try String(contentsOf: fixtureDirectory.appendingPathComponent("stdin"),
                                       encoding: .utf8)
        return FakeInvocation(arguments: arguments, standardInput: standardInput,
                              environment: [:], events: events)
    }

    private func decodeCodexInstructionEnvelope(_ input: String) throws -> [String: String] {
        let marker = "GLANCE_INSTRUCTION_ENVELOPE_JSON\n"
        guard let range = input.range(of: marker) else {
            throw FakeProviderError.missingInstructionEnvelope
        }
        let json = Data(input[range.upperBound...].utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: String])
    }

    private func codexReadOnlyArguments(model: String? = nil) -> [String] {
        var arguments = ["exec", "--json", "--skip-git-repo-check",
                         "--sandbox", "read-only", "--approve-for-me",
                         "-c", "sandbox_workspace_write.network_access=false"]
        if let model { arguments += ["--model", model] }
        arguments += ["--cd", FileManager.default.temporaryDirectory.path, "-"]
        return arguments
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

    private func makeIgnoringTermExecutable(in directory: URL) throws -> URL {
        try makeExecutable(in: directory, script: #"""
        #!/bin/sh
        fixture_dir="$(dirname "$0")"
        trap '' TERM
        printf '%s' "$$" > "$fixture_dir/pid"
        exec /bin/sleep 60
        """#)
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 2) {
        let appeared = expectation(description: "\(url.lastPathComponent) appears")
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: url.path) {
                    appeared.fulfill()
                    return
                }
                usleep(10_000)
            }
        }
        wait(for: [appeared], timeout: timeout + 0.5)
    }

    private func processID(from url: URL) throws -> pid_t {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func waitForProcessExit(_ processID: pid_t, timeout: TimeInterval) {
        let exited = expectation(description: "process \(processID) exits")
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if Darwin.kill(processID, 0) == -1, errno == ESRCH {
                    exited.fulfill()
                    return
                }
                usleep(10_000)
            }
        }
        wait(for: [exited], timeout: timeout + 0.5)
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
    case missingInstructionEnvelope
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

final class ManualAutomationProviderSpy: AutomationProvider {
    let descriptor: AutomationProviderDescriptor
    private(set) var requests: [AutomationRequest] = []
    private(set) var cancellationCounts: [Int] = []
    private var handlers: [(AutomationEvent) -> Void] = []

    init(kind: AskBackendKind) {
        descriptor = AutomationProviderDescriptor(kind: kind, version: "test")
    }

    func runText(_ request: AutomationRequest,
                 onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        let index = requests.count
        requests.append(request)
        cancellationCounts.append(0)
        handlers.append(onEvent)
        return AutomationCancellation { [weak self] in
            self?.cancellationCounts[index] += 1
        }
    }

    func startRun(_ request: AutomationRunRequest,
                  onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        runText(AutomationRequest(prompt: request.prompt, model: request.model), onEvent: onEvent)
    }

    func runComposio(_ request: ComposioAutomationRequest, token: String,
                     onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        runText(AutomationRequest(prompt: request.prompt), onEvent: onEvent)
    }

    func cancelAll() {}

    func emit(_ event: AutomationEvent, forRequestAt index: Int) {
        handlers[index](event)
    }
}

final class ConcurrentTaskAIProviderSpy: AutomationProvider {
    let descriptor = AutomationProviderDescriptor(kind: .codex, version: "test")
    var onFinished: (() -> Void)?

    private let textEventCount: Int
    private let queue = DispatchQueue(label: "task-ai-concurrent-provider",
                                      attributes: .concurrent)

    init(textEventCount: Int) {
        self.textEventCount = textEventCount
    }

    func runText(_ request: AutomationRequest,
                 onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        let eventSink = ConcurrentEventSink(onEvent)
        let textEvents = DispatchGroup()
        let textStart = DispatchSemaphore(value: 0)
        for _ in 0..<textEventCount {
            textEvents.enter()
            queue.async {
                textStart.wait()
                eventSink.send(.text("x"))
                textEvents.leave()
            }
        }
        for _ in 0..<textEventCount { textStart.signal() }

        textEvents.notify(queue: queue) { [weak self] in
            guard let self else { return }
            // Complete only after every concurrent text callback returns, so the
            // expected aggregate is deterministic. The late terminal events
            // still race each other after completion and must be ignored.
            eventSink.send(.completed)
            let lateTerminals = DispatchGroup()
            for event in [AutomationEvent.failed("late failure"), .completed] {
                lateTerminals.enter()
                self.queue.async {
                    eventSink.send(event)
                    lateTerminals.leave()
                }
            }
            lateTerminals.notify(queue: self.queue) { [weak self] in self?.onFinished?() }
        }
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

    func cancelAll() {}
}

private final class ConcurrentEventSink: @unchecked Sendable {
    private let onEvent: (AutomationEvent) -> Void

    init(_ onEvent: @escaping (AutomationEvent) -> Void) {
        self.onEvent = onEvent
    }

    func send(_ event: AutomationEvent) {
        onEvent(event)
    }
}
