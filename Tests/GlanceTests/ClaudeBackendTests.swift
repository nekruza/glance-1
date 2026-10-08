import XCTest
@testable import Glance

extension AskBackendEvent: Equatable {
    public static func == (lhs: AskBackendEvent, rhs: AskBackendEvent) -> Bool {
        switch (lhs, rhs) {
        case let (.token(lhsText), .token(rhsText)):
            return lhsText == rhsText
        case (.completed, .completed):
            return true
        case let (.failed(lhsMessage), .failed(rhsMessage)):
            return lhsMessage == rhsMessage
        case let (.model(lhsID), .model(rhsID)):
            return lhsID == rhsID
        case let (.commandOutput(lhsText), .commandOutput(rhsText)):
            return lhsText == rhsText
        default:
            return false
        }
    }
}

final class ClaudeBackendTests: XCTestCase {
    func testMapsTextDeltaToTokenEvent() throws {
        let fixture = #"""
        {
          "type": "stream_event",
          "event": {
            "type": "content_block_delta",
            "delta": { "type": "text_delta", "text": "hello" }
          }
        }
        """#.data(using: .utf8)!

        let line = try JSONDecoder().decode(StreamLine.self, from: fixture)
        XCTAssertEqual(line.askBackendEvent, .token("hello"))
    }

    func testMapsInitLineModelToModelEvent() throws {
        let fixture = #"""
        {
          "type": "system",
          "subtype": "init",
          "session_id": "abc",
          "model": "claude-fable-5-1",
          "claude_code_version": "2.1.266"
        }
        """#.data(using: .utf8)!

        let line = try JSONDecoder().decode(StreamLine.self, from: fixture)
        XCTAssertEqual(line.askBackendEvent, .model("claude-fable-5-1"))
    }

    func testHookSystemLineWithoutModelProducesNoEvent() throws {
        let fixture = #"""
        { "type": "system", "subtype": "hook_started", "session_id": "abc", "hook_name": "x" }
        """#.data(using: .utf8)!

        let line = try JSONDecoder().decode(StreamLine.self, from: fixture)
        XCTAssertNil(line.askBackendEvent)
    }

    func testPrettifyKnownModelIDs() {
        XCTAssertEqual(ModelCatalog.prettify("claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(ModelCatalog.prettify("claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(ModelCatalog.prettify("claude-haiku-4-5-20251001"), "Haiku 4.5")
    }

    func testShutdownForceKillsClaudeProcessThatIgnoresTermination() throws {
        let fixture = try IgnoringTerminationFixture(prefix: "claude-shutdown")
        defer { fixture.cleanup() }
        let backend = ClaudeBackend(binaryPath: fixture.executable.path)
        backend.startWarm()
        fixture.waitForLaunch(in: self)
        let processID = try fixture.processID()
        defer { Darwin.kill(processID, SIGKILL) }

        backend.shutdown()

        fixture.waitForExit(processID, in: self)
    }

    /// Clear/History replace the backend: the old one's shutdown cleanup must
    /// not delete the folder the new one launches its CLI in. (Seen live as
    /// "Backend not ready." on every question until relaunch.)
    func testReplacedBackendCleanupDoesNotBreakTheNextLaunch() throws {
        let fixture = try IgnoringTerminationFixture(prefix: "claude-shared-cwd")
        defer { fixture.cleanup() }
        let old = ClaudeBackend(binaryPath: fixture.executable.path)
        old.startWarm()
        fixture.waitForLaunch(in: self)
        let oldPID = try fixture.processID()
        defer { Darwin.kill(oldPID, SIGKILL) }

        let quietCLI = fixture.directory.appendingPathComponent("quiet-cli")
        try Data("#!/bin/sh\nexec cat >/dev/null\n".utf8).write(to: quietCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: quietCLI.path)
        let replacement = ClaudeBackend(binaryPath: quietCLI.path)
        defer { replacement.shutdown() }
        old.shutdown()
        fixture.waitForExit(oldPID, in: self)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1)) // cleanup lands

        var events: [AskBackendEvent] = []
        let answered = expectation(description: "first event or silence")
        answered.isInverted = true
        replacement.ask(question: "hi", imagePNG: nil) { event in
            events.append(event)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 0.5)
        XCTAssertEqual(events, [], "the CLI launched and is waiting for the question")
    }

    /// An idle CLI exiting between questions is not a failed turn: the last
    /// finished answer must stay, and the next question respawns the CLI.
    func testIdleExitAfterCompletedTurnDoesNotFailThatTurn() throws {
        let fixture = try IgnoringTerminationFixture(prefix: "claude-idle-exit")
        defer { fixture.cleanup() }
        let cli = fixture.directory.appendingPathComponent("one-answer-cli")
        let script = #"""
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in *'"type":"user"'*)
            printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}}'
            printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"hi"}'
            sleep 0.2; exit 0 ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let backend = ClaudeBackend(binaryPath: cli.path)
        defer { backend.shutdown() }

        var first: [AskBackendEvent] = []
        backend.ask(question: "one", imagePNG: nil) { first.append($0) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.8)) // answer + idle exit
        XCTAssertEqual(first, [.token("hi"), .completed], "the exit after the answer isn't reported to it")

        var second: [AskBackendEvent] = []
        let answered = expectation(description: "respawned CLI answers")
        backend.ask(question: "two", imagePNG: nil) { event in
            second.append(event)
            if case .completed = event { answered.fulfill() }
        }
        wait(for: [answered], timeout: 2)
        XCTAssertEqual(second.prefix(2), [.token("hi"), .completed])
    }

    /// If launching does fail, the real reason reaches the question that
    /// triggered it instead of a bare "Backend not ready.".
    func testLaunchFailureReportsTheRealReason() {
        let backend = ClaudeBackend(binaryPath: "/nonexistent/claude")
        defer { backend.shutdown() }
        var message: String?
        let failed = expectation(description: "failure")
        backend.ask(question: "hi", imagePNG: nil) { event in
            if case .failed(let text) = event, message == nil { message = text; failed.fulfill() }
        }
        wait(for: [failed], timeout: 2)
        XCTAssertTrue(message?.hasPrefix("Couldn't launch Claude CLI") == true, message ?? "nil")
    }
}

private final class IgnoringTerminationFixture {
    let directory: URL
    let executable: URL

    init(prefix: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("fake-cli")
        let script = #"""
        #!/bin/sh
        trap '' TERM
        printf '%s' "$$" > "$(dirname "$0")/pid"
        exec /bin/sleep 60
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func waitForLaunch(in testCase: XCTestCase, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("pid").path),
              Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pid").path))
    }

    func processID() throws -> pid_t {
        let value = try String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8)
        return try XCTUnwrap(pid_t(value))
    }

    func waitForExit(_ pid: pid_t, in testCase: XCTestCase, timeout: TimeInterval = 1.5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Darwin.kill(pid, 0) == -1, errno == ESRCH { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Process \(pid) did not exit")
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
