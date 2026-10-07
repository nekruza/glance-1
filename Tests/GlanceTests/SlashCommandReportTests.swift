import XCTest
@testable import Glance

final class SlashCommandReportTests: XCTestCase {

    private let cli: [SlashCommand] = [
        SlashCommand(name: "compact", description: "Free up context", builtin: true),
        SlashCommand(name: "context", description: "Show current context usage", builtin: true),
        SlashCommand(name: "explain-simple", description: "Clear, literal explanations (user)"),
        SlashCommand(name: "superpowers:brainstorming", description: "(superpowers) Explore intent"),
        SlashCommand(name: "superpowers:writing-plans", description: "(superpowers) Write plans"),
    ]

    func testStatusReportsVersionModelAccountConnectivityAndTools() {
        let report = SlashCommandReport.status(.init(
            backendLabel: "Claude CLI connected · claude 2.1.292",
            connected: true,
            modelName: nil,
            defaultModel: "claude-opus-5-5",
            account: ClaudeAccount(email: "me@kato.app", organization: "Kato",
                                   subscriptionType: "Claude Team", apiProvider: "firstParty"),
            mcpServers: [McpServerStatus(name: "github", status: "connected"),
                         McpServerStatus(name: "gmail", status: "failed"),
                         McpServerStatus(name: "asana", status: "needs-auth")],
            commands: cli))
        XCTAssertTrue(report.contains("claude 2.1.292"), report)
        XCTAssertTrue(report.contains("Opus 5.5"), report)
        XCTAssertTrue(report.contains("me@kato.app"), report)
        XCTAssertTrue(report.contains("Kato"), report)
        XCTAssertTrue(report.contains("Claude Team"), report)
        XCTAssertTrue(report.contains("Connected"), report)
        XCTAssertTrue(report.contains("1 connected"), report)
        XCTAssertTrue(report.contains("1 failed"), report)
        XCTAssertTrue(report.contains("1 need auth"), report)
        XCTAssertTrue(report.contains("gmail"), report)
        XCTAssertTrue(report.contains("3 skills"), report)
    }

    func testStatusPrefersTheModelTheSessionReported() {
        let report = SlashCommandReport.status(.init(
            backendLabel: "Claude CLI connected · claude 2.1.292", connected: true,
            modelName: "Fable 5.1", defaultModel: "claude-opus-5-5",
            account: nil, mcpServers: nil, commands: []))
        XCTAssertTrue(report.contains("Fable 5.1"))
        XCTAssertFalse(report.contains("Opus 5.5"))
        XCTAssertTrue(report.contains("after the first message"), "MCP state unknown until init")
    }

    func testStatusWhenDisconnected() {
        let report = SlashCommandReport.status(.init(
            backendLabel: "Claude CLI not connected", connected: false,
            modelName: nil, defaultModel: nil, account: nil, mcpServers: nil, commands: []))
        XCTAssertTrue(report.contains("Not connected"), report)
    }

    func testSkillsListsNonBuiltinCommandsGroupedByPlugin() {
        let report = SlashCommandReport.skills(cli)
        XCTAssertFalse(report.contains("/compact"))
        XCTAssertTrue(report.contains("/explain-simple"))
        XCTAssertTrue(report.contains("superpowers"))
        XCTAssertTrue(report.contains("/superpowers:brainstorming"))
        XCTAssertLessThan(report.range(of: "/explain-simple")!.lowerBound,
                          report.range(of: "/superpowers:brainstorming")!.lowerBound,
                          "your own skills first, then plugins")
    }

    func testSkillsWhenCatalogNotLoadedYet() {
        XCTAssertTrue(SlashCommandReport.skills([]).contains("No skills"))
    }

    func testHelpListsEveryCommandWithItsDescription() {
        let all = SlashCommandMatcher.merge(cli: cli, hidden: [])
        let report = SlashCommandReport.help(all)
        XCTAssertTrue(report.contains("/status"))
        XCTAssertTrue(report.contains("/context"))
        XCTAssertTrue(report.contains("Show current context usage"))
        XCTAssertTrue(report.contains("Tab"), "explains the menu keys")
    }
}
