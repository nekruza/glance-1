import XCTest
@testable import Glance

@MainActor
final class SlashMenuSessionTests: XCTestCase {

    private func makeSession() -> OverlaySession {
        let session = OverlaySession()
        session.cliCommands = [
            SlashCommand(name: "context", description: "Show current context usage"),
            SlashCommand(name: "compact", description: "Free up context", argumentHint: "<instructions>"),
            SlashCommand(name: "slides", description: "Make a new Slides deck"),
            SlashCommand(name: "doctor", description: "Diagnose the install"),
        ]
        return session
    }

    func testMenuOpensOnSlashAndClosesForPlainTextOrArguments() {
        let session = makeSession()
        XCTAssertTrue(session.slashMatches.isEmpty)
        session.input = "/"
        XCTAssertFalse(session.slashMatches.isEmpty)
        session.input = "/compact now"
        XCTAssertTrue(session.slashMatches.isEmpty)
        session.input = "hello"
        XCTAssertTrue(session.slashMatches.isEmpty)
    }

    func testMenuIncludesLocalCommandsAndHidesTerminalOnlyOnes() {
        let session = makeSession()
        session.terminalOnlyCommands = ["doctor"]
        session.input = "/"
        let names = session.slashMatches.map(\.command.name)
        XCTAssertTrue(names.contains("status"))
        XCTAssertTrue(names.contains("skills"))
        XCTAssertTrue(names.contains("context"))
        XCTAssertFalse(names.contains("doctor"))
    }

    func testArrowSelectionWrapsAndResetsWhenTyping() {
        let session = makeSession()
        session.terminalOnlyCommands = ["doctor"] // d-o-c… would fuzzy-match "co"
        session.input = "/co" // compact, context
        XCTAssertEqual(session.slashMatches.count, 2)
        session.moveSlashSelection(1)
        XCTAssertEqual(session.slashSelection, 1)
        session.moveSlashSelection(1)
        XCTAssertEqual(session.slashSelection, 0)
        session.moveSlashSelection(-1)
        XCTAssertEqual(session.slashSelection, 1)
        session.input = "/con"
        XCTAssertEqual(session.slashSelection, 0)
    }

    func testTabCompletesSelectedCommandWithTrailingSpace() {
        let session = makeSession()
        session.input = "/cont"
        XCTAssertTrue(session.completeSlash())
        XCTAssertEqual(session.input, "/context ")
        XCTAssertTrue(session.slashMatches.isEmpty)
        XCTAssertFalse(session.completeSlash())
    }

    func testReturnRunsSelectedCommand() {
        let session = makeSession()
        var sent: [String] = []
        session.submitHandler = { sent.append($0) }
        session.input = "/cont"
        XCTAssertTrue(session.runSelectedSlash())
        XCTAssertEqual(sent, ["/context"])
        XCTAssertEqual(session.turns.last?.question, "/context")
        XCTAssertEqual(session.input, "")
    }

    func testEscapeHidesMenuUntilTheInputChanges() {
        let session = makeSession()
        session.input = "/c"
        XCTAssertTrue(session.dismissSlashMenu())
        XCTAssertTrue(session.slashMatches.isEmpty)
        XCTAssertFalse(session.dismissSlashMenu(), "second Esc falls through to closing the overlay")
        session.input = "/co"
        XCTAssertFalse(session.slashMatches.isEmpty)
    }

    func testNoMenuActionsWhenNothingMatches() {
        let session = makeSession()
        session.input = "/zzqx"
        XCTAssertFalse(session.runSelectedSlash())
        XCTAssertFalse(session.completeSlash())
        XCTAssertFalse(session.dismissSlashMenu())
    }
}
