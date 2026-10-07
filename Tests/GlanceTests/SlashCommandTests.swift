import XCTest
@testable import Glance

final class SlashCommandTests: XCTestCase {

    private func cmd(_ name: String, _ description: String = "", hint: String? = nil,
                     aliases: [String]? = nil, builtin: Bool? = nil) -> SlashCommand {
        SlashCommand(name: name, description: description, argumentHint: hint,
                     aliases: aliases, builtin: builtin)
    }

    private lazy var catalog: [SlashCommand] = [
        cmd("status", "Show Claude Code status including version, model, account"),
        cmd("slides", "Make a new Slides deck artifact from a brief"),
        cmd("skills", "List available skills"),
        cmd("simplify", "Review the changed code for reuse"),
        cmd("compact", "Free up context by summarizing the conversation so far"),
        cmd("context", "Show current context usage"),
        cmd("superpowers:brainstorming", "Explores user intent before implementation"),
        cmd("clear", "Start a new session with empty context", aliases: ["reset", "new"]),
    ]

    // MARK: - Menu trigger

    func testQueryIsTextAfterLeadingSlashWhileTypingTheName() {
        XCTAssertEqual(SlashCommandMatcher.query(in: "/"), "")
        XCTAssertEqual(SlashCommandMatcher.query(in: "/sk"), "sk")
        XCTAssertEqual(SlashCommandMatcher.query(in: "/superpowers:br"), "superpowers:br")
    }

    func testNoQueryOnceArgumentsStartOrForPlainText() {
        XCTAssertNil(SlashCommandMatcher.query(in: "/skills "))
        XCTAssertNil(SlashCommandMatcher.query(in: "/model opus"))
        XCTAssertNil(SlashCommandMatcher.query(in: "/a\nb"))
        XCTAssertNil(SlashCommandMatcher.query(in: "what is /status"))
        XCTAssertNil(SlashCommandMatcher.query(in: " /status"))
        XCTAssertNil(SlashCommandMatcher.query(in: ""))
    }

    // MARK: - Matching and ranking

    func testEmptyQueryListsEverythingAlphabetically() {
        let names = SlashCommandMatcher.match("", in: catalog).map(\.command.name)
        XCTAssertEqual(names, catalog.map(\.name).sorted())
    }

    func testNamePrefixRanksAboveSubstringAndFuzzy() {
        let names = SlashCommandMatcher.match("s", in: catalog).map(\.command.name)
        // Prefix matches first, shortest name first.
        XCTAssertEqual(Array(names.prefix(5)), ["skills", "slides", "status", "simplify",
                                                "superpowers:brainstorming"])
    }

    func testSegmentPrefixMatchesNamespacedCommands() {
        let matches = SlashCommandMatcher.match("brain", in: catalog)
        XCTAssertEqual(matches.first?.command.name, "superpowers:brainstorming")
        XCTAssertEqual(matches.first?.nameHighlights, Array(12..<17))
    }

    func testFuzzySubsequenceMatchesAndHighlightsEachCharacter() {
        let matches = SlashCommandMatcher.match("cmpt", in: catalog)
        XCTAssertEqual(matches.map(\.command.name), ["compact"])
        XCTAssertEqual(matches.first?.nameHighlights, [0, 2, 3, 6])
    }

    func testAliasPrefixMatches() {
        let matches = SlashCommandMatcher.match("reset", in: catalog)
        XCTAssertEqual(matches.first?.command.name, "clear")
    }

    func testDescriptionOnlyMatchRanksLastAndHighlightsDescription() {
        let matches = SlashCommandMatcher.match("deck", in: catalog)
        XCTAssertEqual(matches.map(\.command.name), ["slides"])
        XCTAssertEqual(matches.first?.nameHighlights, [])
        XCTAssertEqual(matches.first?.descriptionHighlight, 18..<22)
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(SlashCommandMatcher.match("STA", in: catalog).first?.command.name, "status")
    }

    func testNoMatchesForGibberish() {
        XCTAssertTrue(SlashCommandMatcher.match("zzqx", in: catalog).isEmpty)
    }

    // MARK: - Catalog merge

    func testLocalCommandsOverrideCLICommandsAndHiddenOnesDrop() {
        let merged = SlashCommandMatcher.merge(cli: catalog + [cmd("doctor", "Diagnose")],
                                               hidden: ["doctor"])
        XCTAssertEqual(merged.filter { $0.name == "clear" }.count, 1)
        XCTAssertEqual(merged.first { $0.name == "clear" }?.description,
                       LocalSlashCommand.clear.command.description)
        XCTAssertNotNil(merged.first { $0.name == "help" })
        XCTAssertNil(merged.first { $0.name == "doctor" })
    }

    // MARK: - Local command parsing

    func testParsesLocalCommandsWithArguments() {
        XCTAssertEqual(LocalSlashCommand.parse("/status")?.command, .status)
        XCTAssertEqual(LocalSlashCommand.parse("/clear my-name")?.command, .clear)
        XCTAssertEqual(LocalSlashCommand.parse("/clear my-name")?.arguments, "my-name")
        XCTAssertEqual(LocalSlashCommand.parse("/reset")?.command, .clear)
        XCTAssertNil(LocalSlashCommand.parse("/context"))
        XCTAssertNil(LocalSlashCommand.parse("status"))
        XCTAssertNil(LocalSlashCommand.parse("/statusbar"))
    }

    // MARK: - Stream decoding

    func testDecodesCommandCatalogFromInitializeResponse() throws {
        let fixture = #"""
        {"type":"control_response","response":{"subtype":"success","request_id":"glance-init",
         "response":{"commands":[
           {"name":"compact","description":"Free up context","argumentHint":"<instructions>","builtin":true},
           {"name":"superpowers:brainstorming","description":"Explore intent"}],
          "account":{"email":"a@b.c","organization":"Kato","subscriptionType":"Claude Team","apiProvider":"firstParty"},
          "models":[{"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default"},{"value":"opus"}]}}}
        """#.data(using: .utf8)!
        let line = try JSONDecoder().decode(StreamLine.self, from: fixture)
        let catalog = try XCTUnwrap(line.catalog)
        XCTAssertEqual(catalog.commands?.map(\.name), ["compact", "superpowers:brainstorming"])
        XCTAssertEqual(catalog.commands?.first?.argumentHint, "<instructions>")
        XCTAssertEqual(catalog.account?.organization, "Kato")
        XCTAssertEqual(catalog.defaultModel, "claude-opus-5-5")
        XCTAssertNil(line.askBackendEvent)
    }

    func testDecodesCommandsChangedAndTerminalOnlyList() throws {
        let changed = #"""
        {"type":"system","subtype":"commands_changed","commands":[{"name":"loop","description":"Repeat","aliases":["proactive"]}]}
        """#.data(using: .utf8)!
        let a = try JSONDecoder().decode(StreamLine.self, from: changed)
        XCTAssertEqual(a.catalog?.commands?.first?.aliases, ["proactive"])

        let initLine = #"""
        {"type":"system","subtype":"init","model":"claude-opus-5-5","terminal_slash_commands":["doctor","color"],
         "mcp_servers":[{"name":"github","status":"connected","source":"plugin"},{"name":"gmail","status":"failed"}]}
        """#.data(using: .utf8)!
        let b = try JSONDecoder().decode(StreamLine.self, from: initLine)
        XCTAssertEqual(b.catalog?.terminalOnly, ["doctor", "color"])
        XCTAssertEqual(b.catalog?.mcpServers?.map(\.status), ["connected", "failed"])
        XCTAssertEqual(b.askBackendEvent, .model("claude-opus-5-5"))
    }

    func testMalformedCommandEntryDoesNotDropTheLine() throws {
        let fixture = #"""
        {"type":"system","subtype":"commands_changed","commands":[{"name":"ok"},{"description":"no name"}]}
        """#.data(using: .utf8)!
        let line = try JSONDecoder().decode(StreamLine.self, from: fixture)
        XCTAssertEqual(line.catalog?.commands?.map(\.name), ["ok"])
    }
}

extension SlashCommandTests {
    func testUnexpectedCatalogShapesNeverDropATokenLine() throws {
        let fixture = #"""
        {"type":"stream_event","commands":"weird","response":42,"terminal_slash_commands":{"x":1},
         "event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}}
        """#.data(using: .utf8)!
        let line = try JSONDecoder().decode(StreamLine.self, from: fixture)
        XCTAssertEqual(line.askBackendEvent, .token("hi"))
        XCTAssertNil(line.catalog)
    }

    func testSuccessResultTextOnlyForSuccessfulNonEmptyResults() throws {
        func line(_ json: String) throws -> StreamLine {
            try JSONDecoder().decode(StreamLine.self, from: json.data(using: .utf8)!)
        }
        XCTAssertEqual(try line(#"{"type":"result","is_error":false,"result":"Context Usage"}"#).successResultText,
                       "Context Usage")
        XCTAssertNil(try line(#"{"type":"result","is_error":true,"result":"boom"}"#).successResultText)
        XCTAssertNil(try line(#"{"type":"result","is_error":false,"result":""}"#).successResultText)
        XCTAssertNil(try line(#"{"type":"assistant","result":"x"}"#).successResultText)
    }
}
