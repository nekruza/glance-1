import XCTest
@testable import Glance

final class CommandOutputTests: XCTestCase {

    /// Verbatim shape of `claude -p` → `/usage` (2.1.292).
    private let usage = """
    You are currently using your subscription to power your Claude Code usage

    Current session: 36% used · resets Oct 7 at 4:59pm (Europe/London)
    Current week (all models): 24% used · resets Oct 7 at 4:59pm (Europe/London)
    Current week (Fable): 0% used · resets Oct 7 at 5pm (Europe/London)

    What's contributing to your limits usage?
    Approximate, based on local sessions on this machine — does not include other devices or claude.ai.

    Last 24h · 478 requests · 64 sessions
      50% of your usage was at >150k context
      Top skills: /verify 8%
    """

    func testUsageMetersBecomeBars() {
        let lines = CommandOutput.parse(usage)
        let meters = lines.compactMap { line -> (String, Int, String)? in
            if case let .meter(label, percent, detail) = line { return (label, percent, detail) }
            return nil
        }
        XCTAssertEqual(meters.map(\.0), ["Current session", "Current week (all models)", "Current week (Fable)"])
        XCTAssertEqual(meters.map(\.1), [36, 24, 0])
        XCTAssertEqual(meters.first?.2, "Resets Oct 7 at 4:59pm (Europe/London)")
    }

    func testSectionHeadingsAreTitlesAndDetailsKeepTheirIndent() {
        let lines = CommandOutput.parse(usage)
        XCTAssertTrue(lines.contains(.title("What's contributing to your limits usage?")))
        XCTAssertTrue(lines.contains(.title("Last 24h · 478 requests · 64 sessions")))
        XCTAssertTrue(lines.contains(.text("50% of your usage was at >150k context", indent: 2)))
        // A lone sentence before a blank line is body text, not a heading.
        XCTAssertEqual(lines.first, .text("You are currently using your subscription to power your Claude Code usage", indent: 0))
        XCTAssertTrue(lines.contains(.text("Approximate, based on local sessions on this machine — does not include other devices or claude.ai.", indent: 0)))
    }

    func testBlankLinesArePreservedButNotDoubled() {
        let lines = CommandOutput.parse("a\n\n\n\nb")
        XCTAssertEqual(lines, [.text("a", indent: 0), .blank, .text("b", indent: 0)])
    }

    func testMarkdownDetection() {
        XCTAssertTrue(CommandOutput.looksLikeMarkdown("## Context Usage\n\n| a | b |\n|---|---|"))
        XCTAssertTrue(CommandOutput.looksLikeMarkdown("**Model:** x\n- item"))
        XCTAssertTrue(CommandOutput.looksLikeMarkdown("intro\n```\ncode\n```"))
        XCTAssertFalse(CommandOutput.looksLikeMarkdown(usage))
        XCTAssertFalse(CommandOutput.looksLikeMarkdown("Current model: `Opus 5.5` (effort: high)\nUsage: /model <name>."))
        XCTAssertFalse(CommandOutput.looksLikeMarkdown("Not enough messages to compact."))
    }

    func testCLICommandOutputArrivesAsItsOwnEvent() throws {
        // Local commands produce no stream deltas; the result line is the output.
        let line = try JSONDecoder().decode(StreamLine.self, from: #"{"type":"result","is_error":false,"result":"Not enough messages to compact."}"#.data(using: .utf8)!)
        XCTAssertEqual(line.successResultText, "Not enough messages to compact.")
    }

    @MainActor
    func testSessionMarksCommandOutputTurns() {
        let session = OverlaySession()
        session.input = "/usage"
        session.submit()
        session.appendCommandOutput("Current session: 5% used · resets soon")
        XCTAssertEqual(session.turns.last?.isCommandOutput, true)
        XCTAssertEqual(session.turns.last?.answer, "Current session: 5% used · resets soon")
        XCTAssertFalse(session.isWorking)

        session.input = "hello"
        session.submit()
        session.appendToken("hi")
        XCTAssertEqual(session.turns.last?.isCommandOutput, false)
    }
}
