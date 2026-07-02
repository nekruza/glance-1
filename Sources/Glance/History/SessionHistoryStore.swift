import Foundation

/// One past Claude CLI session, listed in the overlay's History dropdown.
struct SessionSummary: Identifiable, Hashable, Sendable {
    let id: String          // Claude session UUID (jsonl file stem)
    let title: String       // first real user message, one line
    let projectLabel: String
    let cwd: String?        // original working directory (needed for --resume)
    let modified: Date
    let fileURL: URL
}

/// Reads Claude CLI's on-disk session store (`~/.claude/projects/<sanitized
/// cwd>/<session-uuid>.jsonl`). Listing parses only the head of each file;
/// full transcripts are parsed lazily when a session is opened.
enum SessionHistoryStore {

    private static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// Newest sessions across all projects. Skips files with no readable user
    /// message in the head (meta/observer sessions).
    static func recentSessions(limit: Int = 15) -> [SessionSummary] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return [] }

        var files: [(url: URL, modified: Date)] = []
        for project in projects {
            guard let items = try? fm.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { continue }
            for item in items where item.pathExtension == "jsonl" {
                let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                files.append((item, date))
            }
        }
        files.sort { $0.modified > $1.modified }

        var out: [SessionSummary] = []
        for file in files.prefix(150) {
            guard out.count < limit else { break }
            if let summary = summarize(file.url, modified: file.modified) {
                out.append(summary)
            }
        }
        return out
    }

    /// Full transcript of one session as (question, answer) pairs for the
    /// overlay. Tool traffic, hooks and sidechains are dropped.
    static func loadTurns(from url: URL) -> [(question: String, answer: String)] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var turns: [(question: String, answer: String)] = []
        for line in text.split(separator: "\n") {
            guard let obj = parse(String(line)) else { continue }
            if let q = userText(obj) {
                turns.append((q, ""))
            } else if let a = assistantText(obj), !turns.isEmpty {
                let sep = turns[turns.count - 1].answer.isEmpty ? "" : "\n\n"
                turns[turns.count - 1].answer += sep + a
            }
        }
        return turns.filter { !$0.answer.isEmpty || !$0.question.isEmpty }
    }

    // MARK: - Listing (head-only parse)

    private static func summarize(_ url: URL, modified: Date) -> SessionSummary? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var title: String?
        var cwd: String?
        // Read in chunks, parsing only complete lines: a Glance question with a
        // screenshot attached is a single multi-MB JSON line (inline base64),
        // and a fixed-size head read would truncate it mid-line and lose the
        // title. Cap the scan so a pathological file can't stall the listing.
        var buffer = Data()
        var scanned = 0
        while scanned < 16 * 1024 * 1024, title == nil || cwd == nil {
            let chunk = handle.readData(ofLength: 256 * 1024)
            if chunk.isEmpty { break }
            scanned += chunk.count
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = Data(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = parse(lineData) else { continue }
                if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
                if title == nil, let t = userText(obj) {
                    title = firstLine(t, cap: 100)
                }
                if title != nil && cwd != nil { break }
            }
        }
        guard let title else { return nil } // nothing user-visible → skip

        // Plugin machinery, not the user's own sessions (claude-mem observers).
        if let cwd, cwd.contains(".claude-mem") { return nil }
        if url.deletingLastPathComponent().lastPathComponent.contains("-claude-mem-") { return nil }

        return SessionSummary(
            id: url.deletingPathExtension().lastPathComponent,
            title: title,
            projectLabel: projectLabel(cwd: cwd, folder: url.deletingLastPathComponent()),
            cwd: cwd,
            modified: modified,
            fileURL: url
        )
    }

    private static func projectLabel(cwd: String?, folder: URL) -> String {
        if let cwd {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            // Glance's own backend sessions run in throwaway temp dirs.
            if name.hasPrefix("glance-") { return "Glance" }
            return name
        }
        return folder.lastPathComponent
    }

    // MARK: - Line extraction

    private static func parse(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return parse(data)
    }

    private static func parse(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Real typed-by-a-human user text; nil for tool results, hook noise,
    /// slash-command tags and sidechain (subagent) traffic.
    private static func userText(_ obj: [String: Any]) -> String? {
        guard obj["type"] as? String == "user",
              (obj["isSidechain"] as? Bool) != true,
              let message = obj["message"] as? [String: Any]
        else { return nil }

        var text: String?
        if let s = message["content"] as? String {
            text = s
        } else if let blocks = message["content"] as? [[String: Any]] {
            text = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("Caveat:"),
              !t.hasPrefix("[Image") // attachment echo line, not a typed message
        else { return nil }
        return t
    }

    private static func assistantText(_ obj: [String: Any]) -> String? {
        guard obj["type"] as? String == "assistant",
              (obj["isSidechain"] as? Bool) != true,
              let message = obj["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]]
        else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        let joined = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func firstLine(_ text: String, cap: Int) -> String {
        var t = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        if t.count > cap { t = String(t.prefix(cap)) + "…" }
        return t
    }
}
