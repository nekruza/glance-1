import XCTest
@testable import Glance

final class PermissionModeTests: XCTestCase {
    // MARK: - Mode

    func testShiftTabCycleSkipsBypass() {
        XCTAssertEqual(PermissionMode.defaultMode, .auto)
        XCTAssertEqual(PermissionMode.auto.next, .manual)
        XCTAssertEqual(PermissionMode.manual.next, .acceptEdits)
        XCTAssertEqual(PermissionMode.acceptEdits.next, .plan)
        XCTAssertEqual(PermissionMode.plan.next, .auto)
        XCTAssertEqual(PermissionMode.bypassPermissions.next, .auto, "⇧Tab leaves bypass for safety")
        XCTAssertFalse(PermissionMode.cycle.contains(.bypassPermissions))
    }

    func testReadsTheModeTheCLIReports() throws {
        XCTAssertEqual(PermissionMode(cliValue: "default"), .manual)
        let status = #"{"type":"system","subtype":"status","status":null,"permissionMode":"acceptEdits"}"#
        let line = try JSONDecoder().decode(StreamLine.self, from: Data(status.utf8))
        XCTAssertEqual(line.reportedPermissionMode, .acceptEdits)
    }

    @MainActor
    func testShiftTabIsMatchedByKeyCode() {
        XCTAssertTrue(OverlayPanel.isModeCycleShortcut(keyCode: 48, modifiers: [.shift]))
        XCTAssertTrue(OverlayPanel.isModeCycleShortcut(keyCode: 48, modifiers: [.shift, .capsLock]))
        XCTAssertFalse(OverlayPanel.isModeCycleShortcut(keyCode: 48, modifiers: []), "plain Tab completes / commands")
        XCTAssertFalse(OverlayPanel.isModeCycleShortcut(keyCode: 48, modifiers: [.shift, .command]))
        XCTAssertFalse(OverlayPanel.isModeCycleShortcut(keyCode: 12, modifiers: [.shift]))
    }

    // MARK: - Requests

    func testParsesAToolRequest() throws {
        let line = #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"rm -rf build","description":"Remove build"},"description":"Remove build"}}"#
        let request = try XCTUnwrap(PermissionRequest.parse(Data(line.utf8)))
        XCTAssertEqual(request.id, "r1")
        XCTAssertEqual(request.detail, "rm -rf build")
        XCTAssertEqual(request.reason, "Remove build")
        XCTAssertFalse(request.isPlanApproval)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: request.inputJSON) as? [String: String])
        XCTAssertEqual(input["command"], "rm -rf build")
    }

    func testParsesAPlanApproval() throws {
        let line = ##"{"type":"control_request","request_id":"r2","request":{"subtype":"can_use_tool","tool_name":"ExitPlanMode","input":{"plan":"# Plan\n1. Do it"}}}"##
        let request = try XCTUnwrap(PermissionRequest.parse(Data(line.utf8)))
        XCTAssertTrue(request.isPlanApproval)
        XCTAssertEqual(request.plan, "# Plan\n1. Do it")
    }

    func testIgnoresOtherLines() {
        XCTAssertNil(PermissionRequest.parse(Data(#"{"type":"control_request","request_id":"x","request":{"subtype":"interrupt"}}"#.utf8)))
        XCTAssertNil(PermissionRequest.parse(Data(#"{"type":"result","subtype":"success"}"#.utf8)))
    }

    // MARK: - Session

    @MainActor
    private func workingSession() -> OverlaySession {
        let session = OverlaySession()
        session.showsPermissionModes = true
        session.input = "do it"
        session.submit()
        return session
    }

    private let bash = PermissionRequest(id: "r1", toolName: "Bash", displayName: "Bash",
                                         inputJSON: Data("{}".utf8), detail: "ls", reason: nil, plan: nil)

    @MainActor
    func testSelectingAndCyclingModes() {
        let session = OverlaySession()
        var sent: [PermissionMode] = []
        session.permissionModeHandler = { sent.append($0) }
        XCTAssertFalse(session.cyclePermissionMode(), "hidden for providers without modes")

        session.showsPermissionModes = true
        session.selectPermissionMode(.plan)
        XCTAssertTrue(session.cyclePermissionMode())
        session.selectPermissionMode(.auto) // already auto: no-op
        XCTAssertEqual(sent, [.plan, .auto])
    }

    @MainActor
    func testAnsweringARequest() {
        let session = workingSession()
        var answers: [(String, Bool)] = []
        session.permissionAnswerHandler = { answers.append(($0.id, $1)) }

        session.showPermissionRequest(bash)
        XCTAssertEqual(session.pendingPermission, bash)
        XCTAssertEqual(session.activity, "Waiting for your approval")

        session.answerPermission(allow: true)
        XCTAssertNil(session.pendingPermission)
        XCTAssertEqual(answers.map(\.0), ["r1"])
        XCTAssertEqual(answers.map(\.1), [true])
        session.answerPermission(allow: false)
        XCTAssertEqual(answers.count, 1, "nothing left to answer")
    }

    @MainActor
    func testRequestsEndWithTheTurn() {
        let session = workingSession()
        session.showPermissionRequest(bash)
        session.stopTurn()
        XCTAssertNil(session.pendingPermission)

        let idle = OverlaySession()
        idle.showPermissionRequest(bash)
        XCTAssertNil(idle.pendingPermission, "no turn in flight")
    }

    @MainActor
    func testProviderChangeResetsToAuto() {
        let session = OverlaySession()
        session.permissionMode = .bypassPermissions
        session.resetForBackendChange(to: .codex)
        XCTAssertEqual(session.permissionMode, .auto)
        XCTAssertFalse(session.showsPermissionModes)
    }

    // MARK: - Claude backend

    /// Fake CLI that asks to use Bash, then reports the answer it got.
    private func askingCLI(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("asking-cli")
        let script = #"""
        #!/bin/sh
        log="$(dirname "$0")/stdin.log"
        while IFS= read -r line; do
          printf '%s\n' "$line" >> "$log"
          case "$line" in
            *'"type":"user"'*)
              printf '%s\n' '{"type":"control_request","request_id":"perm-1","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"ls"}}}' ;;
            *'"request_id":"perm-1"'*)
              # JSON key order isn't fixed: check the decision on its own.
              case "$line" in *'"behavior":"allow"'*) word=allowed ;; *) word=denied ;; esac
              printf '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"%s"}}}\n' "$word"
              printf '{"type":"result","subtype":"success","is_error":false,"result":"%s"}\n' "$word" ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func runTurn(answering allow: Bool) throws -> (events: [AskBackendEvent], stdin: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = ClaudeBackend(binaryPath: try askingCLI(in: dir).path)
        defer { backend.shutdown() }

        var events: [AskBackendEvent] = []
        let done = expectation(description: "turn completes")
        backend.ask(question: "list files", imagePNG: nil) { event in
            events.append(event)
            if case .permissionRequest(let request) = event {
                XCTAssertEqual(request.detail, "ls")
                backend.answerPermission(id: request.id, allow: allow)
            }
            if case .completed = event { done.fulfill() }
        }
        wait(for: [done], timeout: 3)
        let stdin = try String(contentsOf: dir.appendingPathComponent("stdin.log"), encoding: .utf8)
        return (events, stdin)
    }

    func testAllowEchoesTheToolInput() throws {
        let (events, stdin) = try runTurn(answering: true)
        XCTAssertTrue(events.contains(.token("allowed")))
        let reply = try XCTUnwrap(stdin.split(separator: "\n").first { $0.contains("perm-1") })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let decision = try XCTUnwrap((json["response"] as? [String: Any])?["response"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertEqual((decision["updatedInput"] as? [String: String])?["command"], "ls")
    }

    func testDenyTellsClaudeNo() throws {
        let (events, stdin) = try runTurn(answering: false)
        XCTAssertTrue(events.contains(.token("denied")))
        XCTAssertTrue(stdin.contains(#""behavior":"deny""#))
    }

    func testModeSwitchesTheLiveSession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = ClaudeBackend(binaryPath: try askingCLI(in: dir).path)
        defer { backend.shutdown() }
        backend.startWarm()
        backend.setPermissionMode(.plan)

        let log = dir.appendingPathComponent("stdin.log")
        let deadline = Date().addingTimeInterval(2)
        while !(((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("set_permission_mode")),
              Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let request = try XCTUnwrap(try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n").first { $0.contains("set_permission_mode") })
        XCTAssertTrue(request.contains(#""mode":"plan""#))
    }
}
