import XCTest
@testable import Glance

final class OverlaySessionTests: XCTestCase {
    @MainActor
    func testFooterLabelAppendsModelNameWhenKnown() {
        let session = OverlaySession()
        session.backendLabel = "Claude CLI connected · claude 2.1.266"

        XCTAssertEqual(session.footerLabel, "Claude CLI connected · claude 2.1.266")

        session.modelName = "Fable 5.1"
        XCTAssertEqual(session.footerLabel, "Claude CLI connected · claude 2.1.266 · Fable 5.1")
    }

    @MainActor
    func testFooterHidesTheCLIVersion() {
        let session = OverlaySession()
        session.backendLabel = "Claude CLI connected · claude 2.1.294"
        XCTAssertEqual(session.footerStatusLabel, "Claude CLI connected")
        session.backendLabel = "Checking Claude CLI…"
        XCTAssertEqual(session.footerStatusLabel, "Checking Claude CLI…")
    }

    @MainActor
    func testBackendChangeClearsModelName() {
        let session = OverlaySession()
        session.modelName = "Fable 5.1"

        session.resetForBackendChange(to: .codex)

        XCTAssertNil(session.modelName)
    }

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
