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
