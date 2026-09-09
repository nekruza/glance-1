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
