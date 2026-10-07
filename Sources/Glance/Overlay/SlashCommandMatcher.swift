import Foundation

/// One row of the slash-command menu: the command plus which characters of
/// its name / description matched the typed query (drawn bold, as the CLI does).
struct SlashMatch: Equatable {
    let command: SlashCommand
    /// Character offsets into `command.name`.
    let nameHighlights: [Int]
    /// Character range in `command.description`, when the query appears there.
    let descriptionHighlight: Range<Int>?
}

/// Pure filtering/ranking for the `/` menu, modelled on Claude Code's prompt
/// autocomplete: prefix beats word-prefix beats alias beats substring beats
/// fuzzy subsequence beats a description hit; shorter names win ties.
enum SlashCommandMatcher {

    /// The command name being typed, or nil when the menu shouldn't show:
    /// input must start with "/" and still be a single token (no arguments yet).
    static func query(in input: String) -> String? {
        guard input.hasPrefix("/") else { return nil }
        let rest = input.dropFirst()
        guard !rest.contains(where: \.isWhitespace) else { return nil }
        return String(rest)
    }

    /// Local commands first-class, CLI commands after; a CLI command that a
    /// local one replaces, or that only works in the terminal UI, is dropped.
    static func merge(cli: [SlashCommand], hidden: [String]) -> [SlashCommand] {
        let local = LocalSlashCommand.allCases.map(\.command)
        let taken = Set(local.map(\.name)).union(hidden)
        var seen = Set<String>()
        let rest = cli.filter { !taken.contains($0.name) && seen.insert($0.name).inserted }
        return local + rest
    }

    static func match(_ query: String, in commands: [SlashCommand]) -> [SlashMatch] {
        let q = query.lowercased()
        guard !q.isEmpty else {
            return commands.sorted { $0.name < $1.name }
                .map { SlashMatch(command: $0, nameHighlights: [], descriptionHighlight: nil) }
        }
        let qChars = Array(q)
        var ranked: [(tier: Int, match: SlashMatch)] = []
        for command in commands {
            let name = Array(command.name.lowercased())
            let descRange = range(of: qChars, in: Array(command.description.lowercased()))
            func add(_ tier: Int, _ highlights: [Int]) {
                ranked.append((tier, SlashMatch(command: command, nameHighlights: highlights,
                                                descriptionHighlight: descRange)))
            }
            if name.starts(with: qChars) {
                add(0, Array(0..<qChars.count))
            } else if let start = segmentPrefix(qChars, in: name) {
                add(1, Array(start..<start + qChars.count))
            } else if (command.aliases ?? []).contains(where: { $0.lowercased().hasPrefix(q) }) {
                add(2, [])
            } else if let r = range(of: qChars, in: name) {
                add(3, Array(r))
            } else if let indices = subsequence(qChars, in: name) {
                add(4, indices)
            } else if qChars.count >= 3, descRange != nil { // 1–2 letters hit nearly every description
                add(5, [])
            }
        }
        return ranked.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            let an = a.match.command.name, bn = b.match.command.name
            if an.count != bn.count { return an.count < bn.count }
            return an < bn
        }.map(\.match)
    }

    // MARK: - Helpers (character offsets)

    /// Start of a word after ":", "-" or "_" that begins with the query.
    private static func segmentPrefix(_ q: [Character], in name: [Character]) -> Int? {
        for i in name.indices where i > 0 && ":-_".contains(name[i - 1]) {
            if name[i...].starts(with: q) { return i }
        }
        return nil
    }

    private static func range(of q: [Character], in text: [Character]) -> Range<Int>? {
        guard !q.isEmpty, q.count <= text.count else { return nil }
        for i in 0...(text.count - q.count) where text[i..<i + q.count].elementsEqual(q) {
            return i..<i + q.count
        }
        return nil
    }

    private static func subsequence(_ q: [Character], in name: [Character]) -> [Int]? {
        var indices: [Int] = []
        var qi = 0
        for (i, ch) in name.enumerated() where qi < q.count && ch == q[qi] {
            indices.append(i)
            qi += 1
        }
        return qi == q.count ? indices : nil
    }
}
