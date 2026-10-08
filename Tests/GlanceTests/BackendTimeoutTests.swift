import XCTest
@testable import Glance

/// The first-response timeout (FR13) must catch a hung CLI without killing
/// long tool runs, and a timeout must leave the backend usable.
final class BackendTimeoutTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backend-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func executable(_ script: String) throws -> URL {
        let url = directory.appendingPathComponent("fake-cli")
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func collect(_ backend: AskBackend, _ question: String,
                         timeout: TimeInterval = 4) -> [AskBackendEvent] {
        var events: [AskBackendEvent] = []
        let done = expectation(description: "turn ends: \(question)")
        backend.ask(question: question, imagePNG: nil) { event in
            events.append(event)
            switch event {
            case .completed, .failed, .signedOut: done.fulfill()
            default: break
            }
        }
        wait(for: [done], timeout: timeout)
        return events
    }

    /// A tool starts at once, then runs past the timeout before any text.
    func testClaudeToolActivityKeepsTheTurnAlive() throws {
        let cli = try executable(#"""
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in *'"type":"user"'*)
            printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"mcp__jira__search","input":{}}}}'
            sleep 1
            printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"standup"}}}'
            printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"standup"}' ;;
          esac
        done
        """#)
        let backend = ClaudeBackend(binaryPath: cli.path)
        backend.firstTokenTimeout = 0.4
        defer { backend.shutdown() }

        XCTAssertEqual(collect(backend, "give me standup update"),
                       [.activity("Using jira"), .token("standup"), .completed])
    }

    /// The first launch hangs silently; after the timeout the next question
    /// must get a fresh CLI, not "Backend not ready." forever.
    func testClaudeTimeoutLeavesTheBackendUsable() throws {
        let cli = try executable(#"""
        #!/bin/sh
        dir="$(dirname "$0")"
        n=$(ls "$dir" | grep -c '^launch\.')
        touch "$dir/launch.$((n+1))"
        if [ "$n" -eq 0 ]; then exec cat >/dev/null; fi
        while IFS= read -r line; do
          case "$line" in *'"type":"user"'*)
            printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"back"}}}'
            printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"back"}' ;;
          esac
        done
        """#)
        let backend = ClaudeBackend(binaryPath: cli.path)
        backend.firstTokenTimeout = 0.4
        defer { backend.shutdown() }

        XCTAssertEqual(collect(backend, "one"), [.failed("Claude didn't respond within 0s.")])
        XCTAssertEqual(collect(backend, "two"), [.token("back"), .completed])
    }

    /// Codex reports its answer only when the message is complete, so a long
    /// tool run is all it shows before then.
    func testCodexActivityKeepsTheTurnAlive() throws {
        let cli = try executable(#"""
        #!/bin/sh
        printf '{"type":"thread.started","thread_id":"abc"}\n'
        printf '{"type":"item.started","item":{"id":"i1","type":"command_execution","command":"ls"}}\n'
        sleep 1
        printf '{"type":"item.completed","item":{"type":"agent_message","text":"standup"}}\n'
        printf '{"type":"turn.completed","usage":{}}\n'
        """#)
        let backend = CodexBackend(binaryPath: cli.path)
        backend.firstTokenTimeout = 0.4
        defer { backend.shutdown() }

        XCTAssertEqual(collect(backend, "give me standup update"),
                       [.activity("Running a command"), .token("standup"), .completed])
    }
}
