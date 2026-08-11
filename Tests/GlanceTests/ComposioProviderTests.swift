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

    private func fakeCodexComposioInvocation() throws -> ComposioInvocation {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeExecutable(in: fixtureDirectory, script: #"""
        #!/bin/sh
        fixture_dir="$(dirname "$0")"
        printf '%s\n' "$@" > "$fixture_dir/arguments"
        printf '%s' "$GLANCE_COMPOSIO_TOKEN" > "$fixture_dir/token"
        cat > "$fixture_dir/stdin"
        printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"[]"}}'
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

    private func runComposio(provider: AutomationProvider) throws -> [AutomationEvent] {
        let terminal = expectation(description: "Composio provider reaches terminal event")
        var events: [AutomationEvent] = []
        provider.runComposio(
            ComposioAutomationRequest(prompt: "Read my tasks", endpoint: "https://connect.composio.dev/mcp"),
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
