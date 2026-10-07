import XCTest
@testable import Glance

final class WorkingActivityTests: XCTestCase {
    private func event(_ json: String) throws -> AskBackendEvent? {
        try JSONDecoder().decode(StreamLine.self, from: Data(json.utf8)).askBackendEvent
    }

    func testMapsClaudeToolUseStartToActivity() throws {
        let line = #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"Read","input":{}}}}"#
        guard case .activity(let label) = try event(line) else { return XCTFail("expected activity") }
        XCTAssertEqual(label, "Reading files")
    }

    func testMapsClaudeThinkingStartToThinking() throws {
        let line = #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}"#
        guard case .activity(let label) = try event(line) else { return XCTFail("expected activity") }
        XCTAssertEqual(label, "Thinking")
    }

    func testTextBlockStartIsNotActivity() throws {
        let line = #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#
        XCTAssertNil(try event(line))
    }

    func testToolLabels() {
        XCTAssertEqual(ToolActivity.label(forClaudeTool: "Bash"), "Running a command")
        XCTAssertEqual(ToolActivity.label(forClaudeTool: "Grep"), "Searching the code")
        XCTAssertEqual(ToolActivity.label(forClaudeTool: "mcp__claude_ai_Slack__slack_read_thread"),
                       "Using claude ai Slack")
        XCTAssertEqual(ToolActivity.label(forClaudeTool: "Frobnicate"), "Using Frobnicate")
    }

    func testDecodesCodexItemStartedAsActivity() throws {
        let line = #"{"type":"item.started","item":{"id":"i1","type":"command_execution","command":"ls"}}"#
        XCTAssertEqual(try CodexStreamEvent.decode(line), .activity("Running a command"))
        XCTAssertNil(try CodexStreamEvent.decode(line).automationEvent)
        let message = #"{"type":"item.started","item":{"id":"i2","type":"agent_message"}}"#
        XCTAssertEqual(try CodexStreamEvent.decode(message), .ignored)
    }

    @MainActor
    func testTurnStaysWorkingAfterTextUntilCompleted() {
        let session = OverlaySession()
        session.input = "fix it"
        session.submit()
        session.appendToken("Looking at the code.")
        XCTAssertTrue(session.isWorking, "tools may still run after streamed text")
        XCTAssertFalse(session.canSubmit)

        session.setActivity("Reading files")
        XCTAssertEqual(session.activity, "Reading files")
        session.appendToken(" Found it.")
        XCTAssertNil(session.activity, "answer text replaces the tool label")

        session.setActivity("Editing files")
        session.completeTurn()
        XCTAssertFalse(session.isWorking)
        XCTAssertNil(session.activity)
    }

    @MainActor
    func testActivityIgnoredWhenNoTurnInFlight() {
        let session = OverlaySession()
        session.setActivity("Running a command")
        XCTAssertNil(session.activity)
    }

    @MainActor
    func testFailureClearsActivity() {
        let session = OverlaySession()
        session.input = "q"
        session.submit()
        session.setActivity("Running a command")
        session.failTurn("boom")
        XCTAssertFalse(session.isWorking)
        XCTAssertNil(session.activity)
    }
}

final class InputHistoryTests: XCTestCase {
    @MainActor
    private func session(sending messages: [String]) -> OverlaySession {
        let session = OverlaySession()
        for m in messages {
            session.input = m
            session.submit()
            session.completeTurn()
        }
        return session
    }

    @MainActor
    func testUpRecallsNewestFirstThenOlderAndStopsAtOldest() {
        let s = session(sending: ["first", "second", "third"])
        XCTAssertTrue(s.recallOlderMessage()); XCTAssertEqual(s.input, "third")
        XCTAssertTrue(s.recallOlderMessage()); XCTAssertEqual(s.input, "second")
        XCTAssertTrue(s.recallOlderMessage()); XCTAssertEqual(s.input, "first")
        XCTAssertTrue(s.recallOlderMessage()); XCTAssertEqual(s.input, "first")
    }

    @MainActor
    func testDownWalksBackToAnEmptyBox() {
        let s = session(sending: ["first", "second"])
        s.recallOlderMessage(); s.recallOlderMessage()
        XCTAssertTrue(s.recallNewerMessage()); XCTAssertEqual(s.input, "second")
        XCTAssertTrue(s.recallNewerMessage()); XCTAssertEqual(s.input, "")
        XCTAssertFalse(s.recallNewerMessage(), "not browsing any more")
    }

    @MainActor
    func testUpInsideADraftLeavesTheCursorAlone() {
        let s = session(sending: ["first"])
        s.input = "half-typed"
        XCTAssertFalse(s.recallOlderMessage())
        XCTAssertEqual(s.input, "half-typed")
    }

    @MainActor
    func testEditingARecalledMessageEndsBrowsing() {
        let s = session(sending: ["first", "second"])
        s.recallOlderMessage()
        s.input = "second, edited"
        XCTAssertFalse(s.recallOlderMessage())
        XCTAssertFalse(s.recallNewerMessage())
    }

    @MainActor
    func testRecalledSlashCommandKeepsMenuClosed() {
        let s = session(sending: ["/status"])
        s.recallOlderMessage()
        XCTAssertEqual(s.input, "/status")
        XCTAssertTrue(s.slashMatches.isEmpty)
    }

    @MainActor
    func testHistorySurvivesClearAndSkipsRepeats() {
        let s = session(sending: ["same", "same"])
        s.clearTranscript()
        XCTAssertEqual(s.sentHistory, ["same"])
        XCTAssertTrue(s.recallOlderMessage())
        XCTAssertEqual(s.input, "same")
    }

    @MainActor
    func testEmptyHistoryIgnoresUp() {
        XCTAssertFalse(OverlaySession().recallOlderMessage())
    }
}
