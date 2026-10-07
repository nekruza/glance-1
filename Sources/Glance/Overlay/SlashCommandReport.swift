import Foundation

/// Markdown answers for the slash commands Glance runs itself
/// (`LocalSlashCommand`): the headless CLI refuses /status, /skills and /help.
enum SlashCommandReport {

    struct StatusInput {
        /// Footer label, e.g. "Claude CLI connected · claude 2.1.292".
        let backendLabel: String
        let connected: Bool
        /// Model the live session reported ("Fable 5.1"), if any reply yet.
        let modelName: String?
        /// The CLI's default model id from `initialize`.
        let defaultModel: String?
        let account: ClaudeAccount?
        /// Nil until the CLI's init line (sent with the first message).
        let mcpServers: [McpServerStatus]?
        let commands: [SlashCommand]
    }

    static func status(_ s: StatusInput) -> String {
        let parts = s.backendLabel.components(separatedBy: " · ")
        let version = parts.count > 1 ? parts.last! : "—"
        let model = s.modelName
            ?? s.defaultModel.map { "\(ModelCatalog.prettify($0)) (default)" }
            ?? "Reported after the first reply"
        let api: String
        if s.connected {
            api = ["Connected", s.account?.apiProvider].compactMap { $0 }.joined(separator: " · ")
        } else {
            api = "Not connected — \(s.backendLabel)"
        }
        let skills = s.commands.filter { $0.builtin != true }.count

        var rows: [(String, String)] = [("Version", version), ("Model", model)]
        if let account = s.account {
            let who = [account.email, account.organization].compactMap { $0 }.joined(separator: " · ")
            if !who.isEmpty { rows.append(("Account", who)) }
            if let plan = account.subscriptionType { rows.append(("Plan", plan)) }
        }
        rows.append(("API", api))
        rows.append(("MCP servers", mcpSummary(s.mcpServers)))
        rows.append(("Commands", "\(s.commands.count) (\(skills) skills)"))

        var out = "**Claude Code status**\n\n| Setting | Value |\n|---|---|\n"
        out += rows.map { "| \($0.0) | \($0.1) |" }.joined(separator: "\n")
        if let servers = s.mcpServers {
            for (label, status) in [("Failed", "failed"), ("Needs auth", "needs-auth")] {
                let names = servers.filter { $0.status == status }.map(\.name)
                if !names.isEmpty { out += "\n\n**\(label):** " + names.joined(separator: ", ") }
            }
        }
        return out
    }

    static func skills(_ cli: [SlashCommand]) -> String {
        let skills = cli.filter { $0.builtin != true }
        guard !skills.isEmpty else {
            return "No skills loaded yet — the list arrives a few seconds after the Claude CLI starts."
        }
        var groups: [String: [SlashCommand]] = [:]
        for skill in skills {
            let group = skill.name.contains(":")
                ? String(skill.name.split(separator: ":").first!)
                : ""
            groups[group, default: []].append(skill)
        }
        var out = "**Skills** — \(skills.count) available. Type `/` and start typing a name to run one."
        for group in groups.keys.sorted() { // "" (your own) sorts first
            out += "\n\n**\(group.isEmpty ? "Your skills & commands" : group)**\n"
            out += groups[group]!.sorted { $0.name < $1.name }.map(line).joined(separator: "\n")
        }
        return out
    }

    static func help(_ all: [SlashCommand]) -> String {
        "**Commands** — type `/` to open the menu: ↑↓ to choose, Tab to complete, ↩ to run, Esc to close.\n\n"
            + all.map(line).joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func line(_ c: SlashCommand) -> String {
        "- `/\(c.name)` — \(clean(c.description))"
    }

    /// Drop the CLI's provenance tags — "(superpowers) …", "… (user)" — and
    /// keep each entry to one readable line.
    private static func clean(_ description: String) -> String {
        var d = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if d.hasPrefix("("), let close = d.firstIndex(of: ")") {
            d = String(d[d.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        for tag in [" (user)", " (project)", " (plugin)"] where d.hasSuffix(tag) {
            d = String(d.dropLast(tag.count))
        }
        d = d.replacingOccurrences(of: "\n", with: " ")
        return d.count > 120 ? String(d.prefix(119)) + "…" : d
    }

    private static func mcpSummary(_ servers: [McpServerStatus]?) -> String {
        guard let servers else { return "Reported after the first message" }
        guard !servers.isEmpty else { return "None" }
        let counts = Dictionary(grouping: servers, by: \.status).mapValues(\.count)
        let known: [(String, String)] = [("connected", "connected"), ("needs-auth", "need auth"),
                                         ("failed", "failed"), ("pending", "pending")]
        var parts = known.compactMap { key, label in counts[key].map { "\($0) \(label)" } }
        let other = counts.filter { k, _ in !known.contains { $0.0 == k } }.values.reduce(0, +)
        if other > 0 { parts.append("\(other) other") }
        return parts.joined(separator: " · ")
    }
}
