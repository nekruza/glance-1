import XCTest
@testable import Glance

final class CodexStreamEventTests: XCTestCase {
    func testDecodesThreadStarted() throws {
        XCTAssertEqual(try CodexStreamEvent.decode(#"{"type":"thread.started","thread_id":"abc"}"#), .threadStarted("abc"))
    }

    func testDecodesCompletedAgentMessage() throws {
        XCTAssertEqual(try CodexStreamEvent.decode(#"{"type":"item.completed","item":{"type":"agent_message","text":"Hello"}}"#), .token("Hello"))
    }

    func testIgnoresNonFatalCompletedErrorItem() throws {
        let line = #"{"type":"item.completed","item":{"type":"error","message":"Skill descriptions were shortened."}}"#
        XCTAssertEqual(try CodexStreamEvent.decode(line), .ignored)
    }

    func testBackendLaunchesFirstTurnThenResumesAndCleansImage() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-backend-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let executable = fixtureDirectory.appendingPathComponent("fake-codex")
        let script = #"""
        #!/bin/sh
        fixture_dir="$(dirname "$0")"
        count_file="$fixture_dir/count"
        count=0
        if [ -f "$count_file" ]; then count="$(cat "$count_file")"; fi
        count=$((count + 1))
        printf '%s' "$count" > "$count_file"
        printf '%s\n' "$@" > "$fixture_dir/args.$count"
        printf '{"type":"thread.'
        sleep 0.05
        printf 'started","thread_id":"abc"}\n'
        printf '{"type":"item.completed","item":{"type":"agent_message","text":"Hello"}}\n'
        printf '{"type":"turn.completed","usage":{}}\n'
        sleep 0.5
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let backend = CodexBackend(binaryPath: executable.path)
        defer { backend.shutdown() }

        let firstCompleted = expectation(description: "first turn completes")
        var firstEvents: [AskBackendEvent] = []
        backend.ask(question: "First", imagePNG: Data([0x89, 0x50, 0x4E, 0x47])) { event in
            firstEvents.append(event)
            if case .completed = event { firstCompleted.fulfill() }
        }
        wait(for: [firstCompleted], timeout: 2)

        let firstArguments = try String(contentsOf: fixtureDirectory.appendingPathComponent("args.1"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(firstArguments.prefix(3)), ["exec", "--json", "--skip-git-repo-check"])
        XCTAssertEqual(firstArguments.suffix(1), ["First"])
        XCTAssertEqual(firstEvents, [.token("Hello"), .completed])
        let imageFlag = try XCTUnwrap(firstArguments.firstIndex(of: "--image"))
        let imagePath = firstArguments[imageFlag + 1]
        XCTAssertFalse(FileManager.default.fileExists(atPath: imagePath))

        let secondCompleted = expectation(description: "follow-up completes")
        backend.ask(question: "Second", imagePNG: nil) { event in
            if case .completed = event { secondCompleted.fulfill() }
        }
        wait(for: [secondCompleted], timeout: 2)

        let secondArguments = try String(contentsOf: fixtureDirectory.appendingPathComponent("args.2"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(secondArguments, ["exec", "resume", "abc", "--json", "--skip-git-repo-check", "Second"])
    }
}
