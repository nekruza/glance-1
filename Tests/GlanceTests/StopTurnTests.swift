import XCTest
@testable import Glance

final class StopTurnTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stop-turn-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Session

    @MainActor
    func testStopEndsTheTurnAndKeepsThePartialAnswer() {
        let session = OverlaySession()
        var stopped = 0
        session.stopHandler = { stopped += 1 }
        session.input = "long task"
        session.submit()
        session.appendToken("Half an answer")
        session.setActivity("Running a command")

        session.stopTurn()

        XCTAssertEqual(stopped, 1)
        XCTAssertFalse(session.isWorking)
        XCTAssertNil(session.activity)
        XCTAssertTrue(session.lastTurnStopped)
        XCTAssertEqual(session.turns.last?.answer, "Half an answer")
        session.input = "next"
        XCTAssertTrue(session.canSubmit, "a follow-up can go right away")
    }

    @MainActor
    func testStopDoesNothingWhenIdle() {
        let session = OverlaySession()
        var stopped = 0
        session.stopHandler = { stopped += 1 }
        session.stopTurn()
        XCTAssertEqual(stopped, 0)
    }

    // MARK: - Claude: interrupt control request

    /// Fake CLI that mirrors claude 2.1.292: after `interrupt` it still emits
    /// stale output, then an `error_during_execution` result for the stopped turn.
    func testClaudeInterruptDropsTheStoppedTurnAndContinuesTheSession() throws {
        let cli = try executable(#"""
        #!/bin/sh
        log="$(dirname "$0")/stdin.log"
        n=0
        while IFS= read -r line; do
          printf '%s\n' "$line" >> "$log"
          case "$line" in
            *'"subtype":"interrupt"'*)
              printf '%s\n' '{"type":"control_response","response":{"subtype":"success"}}'
              printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"late"}}}'
              printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true}' ;;
            *'"type":"user"'*)
              n=$((n+1))
              if [ "$n" -eq 1 ]; then
                printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"partial"}}}'
              else
                printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"second"}}}'
                printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"second"}'
              fi ;;
          esac
        done
        """#)
        let backend = ClaudeBackend(binaryPath: cli.path)
        defer { backend.shutdown() }

        var first: [AskBackendEvent] = []
        var second: [AskBackendEvent] = []
        let partial = expectation(description: "first turn streams")
        let followUpDone = expectation(description: "follow-up completes")

        backend.ask(question: "one", imagePNG: nil) { event in
            first.append(event)
            if case .token = event { partial.fulfill() }
        }
        wait(for: [partial], timeout: 3)

        backend.interrupt()
        backend.ask(question: "two", imagePNG: nil) { event in
            second.append(event)
            if case .completed = event { followUpDone.fulfill() }
        }
        wait(for: [followUpDone], timeout: 3)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(first, [.token("partial")], "nothing after Stop reaches the stopped turn")
        XCTAssertEqual(second, [.token("second"), .completed], "no stale text or interrupted error leaks in")
        let log = try String(contentsOf: directory.appendingPathComponent("stdin.log"), encoding: .utf8)
        XCTAssertTrue(log.contains(#""subtype":"interrupt""#))
    }

    func testClaudeInterruptWithNoTurnInFlightSendsNothing() throws {
        let cli = try executable(#"""
        #!/bin/sh
        while IFS= read -r line; do printf '%s\n' "$line" >> "$(dirname "$0")/stdin.log"; done
        """#)
        let backend = ClaudeBackend(binaryPath: cli.path)
        defer { backend.shutdown() }
        backend.startWarm()
        backend.interrupt()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let log = (try? String(contentsOf: directory.appendingPathComponent("stdin.log"), encoding: .utf8)) ?? ""
        XCTAssertFalse(log.contains("interrupt"))
    }

    // MARK: - Codex: end the turn's process, resume the thread

    func testCodexInterruptEndsTheTurnSilentlyAndResumesTheThread() throws {
        let cli = try executable(#"""
        #!/bin/sh
        dir="$(dirname "$0")"
        n=$(ls "$dir" | grep -c '^args\.')
        n=$((n+1))
        printf '%s\n' "$@" > "$dir/args.$n"
        if [ "$n" -eq 1 ]; then
          printf '{"type":"thread.started","thread_id":"abc"}\n'
          printf '{"type":"item.completed","item":{"type":"agent_message","text":"partial"}}\n'
          exec sleep 30
        fi
        printf '{"type":"item.completed","item":{"type":"agent_message","text":"second"}}\n'
        printf '{"type":"turn.completed","usage":{}}\n'
        """#)
        let backend = CodexBackend(binaryPath: cli.path)
        defer { backend.shutdown() }

        var first: [AskBackendEvent] = []
        var second: [AskBackendEvent] = []
        let partial = expectation(description: "first turn streams")
        let followUpDone = expectation(description: "follow-up completes")

        backend.ask(question: "one", imagePNG: nil) { event in
            first.append(event)
            if case .token = event { partial.fulfill() }
        }
        wait(for: [partial], timeout: 3)

        backend.interrupt()
        backend.ask(question: "two", imagePNG: nil) { event in
            second.append(event)
            if case .completed = event { followUpDone.fulfill() }
        }
        wait(for: [followUpDone], timeout: 3)

        XCTAssertEqual(first, [.token("partial")], "no 'exited unexpectedly' for a stopped turn")
        XCTAssertEqual(second, [.token("second"), .completed])
        let args = try String(contentsOf: directory.appendingPathComponent("args.2"), encoding: .utf8)
        XCTAssertTrue(args.hasPrefix("exec\nresume\nabc\n"), "follow-up continues the thread")
    }
}
