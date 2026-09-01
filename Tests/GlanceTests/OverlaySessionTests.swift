import XCTest
@testable import Glance

final class OverlaySessionTests: XCTestCase {
    @MainActor
    func testBackendChangeDismissesAndResetsSession() {
        let session = OverlaySession()
        var dismissed = false
        session.dismissHandler = { dismissed = true }
        session.turns = [OverlaySession.Turn(question: "Old question", answer: "Old answer")]
        session.input = "Draft"
        session.attachImage = true
        session.isWorking = true
        session.backendConnected = true
        session.backendLabel = "Claude CLI connected"
        session.showsHistory = true
        session.historyHandler = { _ in }
        session.historySessions = [
            SessionSummary(id: "old", title: "Old session", projectLabel: "Project",
                           cwd: nil, modified: .distantPast,
                           fileURL: URL(fileURLWithPath: "/tmp/old.jsonl"))
        ]

        session.resetForBackendChange(to: .codex)

        XCTAssertTrue(dismissed)
        XCTAssertTrue(session.turns.isEmpty)
        XCTAssertTrue(session.input.isEmpty)
        XCTAssertFalse(session.attachImage)
        XCTAssertFalse(session.isWorking)
        XCTAssertFalse(session.backendConnected)
        XCTAssertEqual(session.backendLabel, "Checking Codex CLI…")
        XCTAssertFalse(session.showsHistory)
        XCTAssertNil(session.historyHandler)
        XCTAssertTrue(session.historySessions.isEmpty)
    }

    @MainActor
    func testBackendChangeRejectsHistoryLoadedForPreviousGeneration() {
        let session = OverlaySession()
        session.resetForBackendChange(to: .claude)
        let claudeGeneration = session.transcriptGeneration
        session.resetForBackendChange(to: .codex)

        let loaded = session.loadTranscript(
            [(question: "Claude question", answer: "Claude answer")],
            ifGeneration: claudeGeneration
        )

        XCTAssertFalse(loaded)
        XCTAssertTrue(session.turns.isEmpty)
    }

    @MainActor
    func testHistoryLoadAppliesForCurrentGeneration() {
        let session = OverlaySession()
        session.resetForBackendChange(to: .claude)

        let loaded = session.loadTranscript(
            [(question: "Current question", answer: "Current answer")],
            ifGeneration: session.transcriptGeneration
        )

        XCTAssertTrue(loaded)
        XCTAssertEqual(session.turns.map(\.question), ["Current question"])
        XCTAssertEqual(session.turns.map(\.answer), ["Current answer"])
    }
}
