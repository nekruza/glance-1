import Foundation

/// One Claude Code slash command (built-in, skill, plugin or user command) as
/// the CLI describes it in its `initialize` control response and
/// `system/commands_changed` lines.
struct SlashCommand: Decodable, Hashable {
    let name: String
    let description: String
    /// e.g. "<model>" or "[interval] [prompt]"; empty/nil when none.
    let argumentHint: String?
    let aliases: [String]?
    let builtin: Bool?

    init(name: String, description: String, argumentHint: String? = nil,
         aliases: [String]? = nil, builtin: Bool? = nil) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.aliases = aliases
        self.builtin = builtin
    }

    enum CodingKeys: String, CodingKey {
        case name, description, argumentHint, aliases, builtin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        argumentHint = try? c.decodeIfPresent(String.self, forKey: .argumentHint)
        aliases = try? c.decodeIfPresent([String].self, forKey: .aliases)
        builtin = try? c.decodeIfPresent(Bool.self, forKey: .builtin)
    }
}

/// Who the CLI is signed in as (`initialize` → `account`), for /status.
struct ClaudeAccount: Decodable, Equatable {
    let email: String?
    let organization: String?
    let subscriptionType: String?
    let apiProvider: String?
}

/// One MCP server as the init line reports it ("connected", "needs-auth",
/// "failed", "pending"…), for /status.
struct McpServerStatus: Decodable, Equatable {
    let name: String
    let status: String
}

/// A model choice from `initialize` → `models`; only the default is used.
struct ModelOption: Decodable {
    let value: String
    let resolvedModel: String?
}

/// Catalog facts carried by one stream line. Each field is nil when that line
/// doesn't speak to it, so updates merge rather than overwrite.
struct BackendCatalog: Equatable {
    var commands: [SlashCommand]?
    var account: ClaudeAccount?
    /// Commands the CLI only runs in its interactive terminal UI
    /// (`terminal_slash_commands` on the init line) — hidden from the menu.
    var terminalOnly: [String]?
    /// MCP servers and their connection state (init line).
    var mcpServers: [McpServerStatus]?
    /// Model id the CLI uses when none is chosen, e.g. "claude-opus-5-5".
    var defaultModel: String?
}

/// Commands Glance answers itself. The CLI refuses these in headless
/// (`-p`) mode ("isn't available in this environment"), or — for /clear —
/// Glance owns the conversation UI that has to reset along with the session.
enum LocalSlashCommand: String, CaseIterable {
    case clear, help, skills, status

    var command: SlashCommand {
        switch self {
        case .clear:
            return SlashCommand(name: "clear",
                                description: "Clear the conversation and start a new session",
                                aliases: ["reset", "new"])
        case .help:
            return SlashCommand(name: "help", description: "Show available commands")
        case .skills:
            return SlashCommand(name: "skills", description: "List available skills")
        case .status:
            return SlashCommand(name: "status",
                                description: "Show Claude Code status including version, model, account, API connectivity, and tool statuses")
        }
    }

    /// "/status", "/reset", "/clear name" → the command plus trailing text.
    static func parse(_ text: String) -> (command: LocalSlashCommand, arguments: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let name = body.prefix { !$0.isWhitespace }.lowercased()
        let args = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = allCases.first(where: {
            $0.rawValue == name || ($0.command.aliases ?? []).contains(name)
        }) else { return nil }
        return (match, args)
    }
}

/// Decodes an array element-by-element, skipping entries that don't decode,
/// so one odd command can't drop the whole stream line.
struct LenientArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                out.append(element)
            } else if (try? container.decode(Skip.self)) == nil {
                break // not even an object: can't advance past it
            }
        }
        elements = out
    }

    private struct Skip: Decodable {}
}
