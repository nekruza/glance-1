import XCTest
@testable import Glance

final class ComposioProviderTests: XCTestCase {
    func testCodexComposioUsesTransientConfigAndChildOnlyBearerToken() throws {
        let invocation = try fakeCodexComposioInvocation()

        XCTAssertEqual(invocation.arguments, [
            "exec", "--json", "--skip-git-repo-check",
            "-c", "mcp_servers.composio.url=\"https://connect.composio.dev/mcp\"",
            "-c", "mcp_servers.composio.bearer_token_env_var=\"GLANCE_COMPOSIO_TOKEN\"",
            "-"
        ])
        XCTAssertEqual(invocation.environment["GLANCE_COMPOSIO_TOKEN"], "secret")
        XCTAssertEqual(invocation.standardInput, "Read my tasks")
        XCTAssertFalse(invocation.arguments.joined(separator: " ").contains("secret"))
        XCTAssertEqual(invocation.events, [.text("["), .text("]"), .completed])
    }

    func testClaudeComposioRetainsPrivateConfigAndToolAllowlist() throws {
        let invocation = try fakeClaudeComposioInvocation()
        let config = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(invocation.configuration.utf8)) as? [String: Any]
        )
        let server = try XCTUnwrap(
            ((config["mcpServers"] as? [String: Any])?["composio"] as? [String: Any])
        )

        XCTAssertEqual(invocation.configurationPermissions, 0o600)
        XCTAssertEqual(server["url"] as? String, "https://connect.composio.dev/mcp")
        XCTAssertEqual((server["headers"] as? [String: String])?["Authorization"], "Bearer secret")
        XCTAssertEqual(invocation.arguments, [
            "-p", "--model", "sonnet", "--mcp-config", invocation.configurationPath,
            "--strict-mcp-config", "--allowedTools",
            "mcp__composio__COMPOSIO_SEARCH_TOOLS",
            "mcp__composio__COMPOSIO_GET_TOOL_SCHEMAS",
            "mcp__composio__COMPOSIO_MULTI_EXECUTE_TOOL",
            "mcp__composio__COMPOSIO_MANAGE_CONNECTIONS"
        ])
        XCTAssertEqual(invocation.events, [.text("[]"), .completed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocation.configurationPath))
    }

    func testSelectedProviderNamesComposioFailure() throws {
        XCTAssertEqual(ComposioIngest.failureMessage(kind: .codex, status: 1),
                       "Composio call failed (Codex CLI exited 1).")
        XCTAssertEqual(try fakeCodexComposioFailureEvents(),
                       [.failed("Composio call failed (Codex CLI exited 1).")])
    }

    func testCodexComposioCancellationInvalidatesCallbacks() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeExecutable(in: fixtureDirectory, script: #"""
        #!/bin/sh
        fixture_dir="$(dirname "$0")"
        printf 'launched' > "$fixture_dir/launched"
        cat >/dev/null
        trap '' TERM
        exec /bin/sleep 60
        """#)
        let provider = CodexAutomationProvider(binaryPath: executable.path, version: "test")
        let staleEvent = expectation(description: "cancelled Composio run emits no event")
        staleEvent.isInverted = true

        let cancellation = provider.runComposio(
            ComposioAutomationRequest(prompt: "Read my tasks", endpoint: "https://connect.composio.dev/mcp"),
            token: "secret"
        ) { _ in
            staleEvent.fulfill()
        }
        waitForFile(fixtureDirectory.appendingPathComponent("launched"))
        cancellation.cancel()

        wait(for: [staleEvent], timeout: 0.4)
        provider.cancelAll()
    }

    func testCodexComposioPreservesTerminalFailureMessage() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeExecutable(in: fixtureDirectory, script: #"""
        #!/bin/sh
        cat >/dev/null
        printf '%s\n' '{"type":"turn.failed","error":{"message":"Composio rejected the request."}}'
        """#)
        let provider = CodexAutomationProvider(binaryPath: executable.path, version: "test")

        XCTAssertEqual(try runComposio(provider: provider),
                       [.failed("Codex CLI: Composio rejected the request.")])
    }

    func testComposioTimeoutNamesSelectedProvider() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeExecutable(in: fixtureDirectory, script: #"""
        #!/bin/sh
        cat >/dev/null
        exec /bin/sleep 60
        """#)
        let provider = CodexAutomationProvider(binaryPath: executable.path, version: "test")

        XCTAssertEqual(try runComposio(provider: provider, timeout: 0.1),
                       [.failed("Composio call timed out (Codex CLI didn't respond within 1s).")])
    }

    func testClaudeComposioCancellationRemovesConfigAndStopsChild() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeComposioSleepingExecutable(in: fixtureDirectory)
        let provider = ClaudeAutomationProvider(binaryPath: executable.path, version: "test")
        let staleEvent = expectation(description: "cancelled Claude Composio run emits no event")
        staleEvent.isInverted = true

        let cancellation = provider.runComposio(
            ComposioAutomationRequest(prompt: "Read my tasks", endpoint: "https://connect.composio.dev/mcp"),
            token: "secret"
        ) { _ in
            staleEvent.fulfill()
        }
        let configPath = try waitForConfigPath(in: fixtureDirectory)
        let processID = try processID(from: fixtureDirectory.appendingPathComponent("pid"))
        cancellation.cancel()

        waitForProcessExit(processID)
        waitForFileRemoval(URL(fileURLWithPath: configPath))
        wait(for: [staleEvent], timeout: 0.3)
    }

    func testClaudeComposioOwnerDeallocationRemovesConfigAndStopsChild() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeComposioSleepingExecutable(in: fixtureDirectory)
        var provider: ClaudeAutomationProvider? = ClaudeAutomationProvider(binaryPath: executable.path, version: "test")
        weak var weakProvider = provider

        provider?.runComposio(
            ComposioAutomationRequest(prompt: "Read my tasks", endpoint: "https://connect.composio.dev/mcp"),
            token: "secret"
        ) { _ in }
        let configPath = try waitForConfigPath(in: fixtureDirectory)
        let processID = try processID(from: fixtureDirectory.appendingPathComponent("pid"))
        provider = nil

        XCTAssertNil(weakProvider)
        waitForProcessExit(processID)
        waitForFileRemoval(URL(fileURLWithPath: configPath))
    }

    func testClaudeComposioLaunchFailureRemovesTransientConfig() throws {
        let before = Self.glanceMCPConfigPaths()
        let provider = ClaudeAutomationProvider(binaryPath: "/nonexistent/glance-claude", version: "test")
        let events = try runComposio(provider: provider)

        guard case .failed(let message) = try XCTUnwrap(events.first) else {
            return XCTFail("Expected launch failure")
        }
        XCTAssertTrue(message.hasPrefix("Couldn't launch Claude CLI:"))
        waitForMCPConfigPaths(before)
    }

    func testComposioIngestAggregatesMultipleProviderTextEvents() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeExecutable(in: fixtureDirectory, script: #"""
        #!/bin/sh
        cat >/dev/null
        printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"["}}'
        printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"]"}}'
        printf '%s\n' '{"type":"turn.completed"}'
        """#)
        let provider = CodexAutomationProvider(binaryPath: executable.path, version: "test")
        let ingest = ComposioIngest(provider: provider)
        let completed = expectation(description: "ingest aggregates provider text")
        let prefs = Preferences.shared
        let oldURL = prefs.composioURL
        let oldKey = prefs.composioKey
        defer {
            prefs.composioURL = oldURL
            prefs.composioKey = oldKey
        }
        prefs.composioURL = "https://connect.composio.dev/mcp"
        prefs.composioKey = "secret"

        ingest.runReadOnly(prompt: "Read my tasks", on: DispatchQueue(label: "composio-ingest-test")) { text, error in
            XCTAssertEqual(text, "[]")
            XCTAssertNil(error)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
    }

    /// Break protected: a provider switch can happen after the provider's
    /// terminal event removed its active request but before the queued main
    /// completion runs. That stale completion must not land tasks or advance
    /// the incremental pull timestamp.
    @MainActor
    func testComposioIngestCancelInvalidatesQueuedPullCompletion() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let store = TaskStore(directory: fixtureDirectory)
        let provider = QueuedPullAutomationProvider()
        let ingest = ComposioIngest(provider: provider)
        let target = ComposioIngest.FetchTarget.app(
            slug: "queued-race-\(UUID().uuidString)",
            name: "Queued race"
        )
        let staleCompletion = expectation(description: "cancelled queued pull does not complete")
        staleCompletion.isInverted = true
        let prefs = Preferences.shared
        let oldURL = prefs.composioURL
        let oldKey = prefs.composioKey
        let defaults = UserDefaults.standard
        let oldLastRuns = defaults.object(forKey: "tasks.pullLastRuns")
        defer {
            prefs.composioURL = oldURL
            prefs.composioKey = oldKey
            if let oldLastRuns {
                defaults.set(oldLastRuns, forKey: "tasks.pullLastRuns")
            } else {
                defaults.removeObject(forKey: "tasks.pullLastRuns")
            }
        }
        prefs.composioURL = "https://connect.composio.dev/mcp"
        prefs.composioKey = "secret"

        ingest.pull(target, store: store) { _ in staleCompletion.fulfill() }
        XCTAssertEqual(provider.terminalHandled.wait(timeout: .now() + 2), .success,
                       "provider must queue its terminal result while the main thread is blocked")
        ingest.cancel()

        wait(for: [staleCompletion], timeout: 0.2)
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertNil(prefs.pullLastRun(target.key))
    }

    private func fakeCodexComposioInvocation() throws -> ComposioInvocation {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeExecutable(in: fixtureDirectory, script: #"""
        #!/bin/sh
        fixture_dir="$(dirname "$0")"
        printf '%s\n' "$@" > "$fixture_dir/arguments"
        printf '%s' "$GLANCE_COMPOSIO_TOKEN" > "$fixture_dir/token"
        cat > "$fixture_dir/stdin"
        printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"["}}'
        printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"]"}}'
        printf '%s\n' '{"type":"turn.completed"}'
        """#)
        let provider = CodexAutomationProvider(binaryPath: executable.path, version: "test")
        let events = try runComposio(provider: provider)

        return ComposioInvocation(
            arguments: try lines(in: fixtureDirectory.appendingPathComponent("arguments")),
            standardInput: try String(contentsOf: fixtureDirectory.appendingPathComponent("stdin"), encoding: .utf8),
            environment: ["GLANCE_COMPOSIO_TOKEN": try String(contentsOf: fixtureDirectory.appendingPathComponent("token"), encoding: .utf8)],
            configurationPath: "",
            configuration: "",
            configurationPermissions: 0,
            events: events
        )
    }

    private func fakeClaudeComposioInvocation() throws -> ComposioInvocation {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeExecutable(in: fixtureDirectory, script: #"""
        #!/bin/sh
        fixture_dir="$(dirname "$0")"
        printf '%s\n' "$@" > "$fixture_dir/arguments"
        config=''
        previous=''
        for argument in "$@"; do
            if [ "$previous" = '--mcp-config' ]; then config="$argument"; break; fi
            previous="$argument"
        done
        printf '%s' "$config" > "$fixture_dir/config-path"
        cat "$config" > "$fixture_dir/config"
        stat -f '%Lp' "$config" > "$fixture_dir/config-permissions"
        printf '[]'
        """#)
        let provider = ClaudeAutomationProvider(binaryPath: executable.path, version: "test")
        let events = try runComposio(provider: provider)

        return ComposioInvocation(
            arguments: try lines(in: fixtureDirectory.appendingPathComponent("arguments")),
            standardInput: "",
            environment: [:],
            configurationPath: try String(contentsOf: fixtureDirectory.appendingPathComponent("config-path"), encoding: .utf8),
            configuration: try String(contentsOf: fixtureDirectory.appendingPathComponent("config"), encoding: .utf8),
            configurationPermissions: try Int(String(contentsOf: fixtureDirectory.appendingPathComponent("config-permissions"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), radix: 8) ?? 0,
            events: events
        )
    }

    private func fakeCodexComposioFailureEvents() throws -> [AutomationEvent] {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeExecutable(in: fixtureDirectory, script: #"""
        #!/bin/sh
        cat >/dev/null
        exit 1
        """#)
        let provider = CodexAutomationProvider(binaryPath: executable.path, version: "test")
        return try runComposio(provider: provider)
    }

    private func runComposio(provider: AutomationProvider, timeout: TimeInterval = 240) throws -> [AutomationEvent] {
        let terminal = expectation(description: "Composio provider reaches terminal event")
        var events: [AutomationEvent] = []
        provider.runComposio(
            ComposioAutomationRequest(prompt: "Read my tasks", endpoint: "https://connect.composio.dev/mcp", timeout: timeout),
            token: "secret"
        ) { event in
            events.append(event)
            if case .completed = event { terminal.fulfill() }
            if case .failed = event { terminal.fulfill() }
        }
        wait(for: [terminal], timeout: 2)
        provider.cancelAll()
        return events
    }

    private func makeFixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("composio-provider-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeExecutable(in directory: URL, script: String) throws -> URL {
        let executable = directory.appendingPathComponent("fake-provider")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func makeComposioSleepingExecutable(in directory: URL) throws -> URL {
        try makeExecutable(in: directory, script: #"""
        #!/bin/sh
        fixture_dir="$(dirname "$0")"
        previous=''
        config=''
        for argument in "$@"; do
            if [ "$previous" = '--mcp-config' ]; then config="$argument"; break; fi
            previous="$argument"
        done
        printf '%s' "$config" > "$fixture_dir/config-path"
        printf '%s' "$$" > "$fixture_dir/pid"
        cat >/dev/null
        trap '' TERM
        exec /bin/sleep 60
        """#)
    }

    private func lines(in url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
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

    private func waitForConfigPath(in directory: URL) throws -> String {
        let url = directory.appendingPathComponent("config-path")
        waitForFile(url)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func processID(from url: URL) throws -> pid_t {
        try XCTUnwrap(pid_t(String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func waitForProcessExit(_ processID: pid_t, timeout: TimeInterval = 1.5) {
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

    private func waitForFileRemoval(_ url: URL, timeout: TimeInterval = 1.5) {
        let removed = expectation(description: "\(url.lastPathComponent) is removed")
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if !FileManager.default.fileExists(atPath: url.path) {
                    removed.fulfill()
                    return
                }
                usleep(10_000)
            }
        }
        wait(for: [removed], timeout: timeout + 0.5)
    }

    private static func glanceMCPConfigPaths() -> Set<String> {
        let directory = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("glance-mcp-") && $0.hasSuffix(".json") })
    }

    private func waitForMCPConfigPaths(_ expected: Set<String>, timeout: TimeInterval = 1) {
        let matched = expectation(description: "transient MCP config is removed")
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if Self.glanceMCPConfigPaths() == expected {
                    matched.fulfill()
                    return
                }
                usleep(10_000)
            }
        }
        wait(for: [matched], timeout: timeout + 0.5)
    }
}

private struct ComposioInvocation {
    let arguments: [String]
    let standardInput: String
    let environment: [String: String]
    let configurationPath: String
    let configuration: String
    let configurationPermissions: Int
    let events: [AutomationEvent]
}

private final class QueuedPullAutomationProvider: AutomationProvider {
    let descriptor = AutomationProviderDescriptor(kind: .codex, version: "test")
    let terminalHandled = DispatchSemaphore(value: 0)

    func runText(_ request: AutomationRequest,
                 onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        AutomationCancellation()
    }

    func startRun(_ request: AutomationRunRequest,
                  onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        AutomationCancellation()
    }

    func runComposio(_ request: ComposioAutomationRequest, token: String,
                     onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        onEvent(.text(#"[{"title":"Stale task","sourceKey":"stale-1"}]"#))
        onEvent(.completed)
        terminalHandled.signal()
        return AutomationCancellation()
    }

    func cancelAll() {}
}
