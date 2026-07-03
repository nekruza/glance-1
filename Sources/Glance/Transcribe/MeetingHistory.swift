import Foundation

/// Saved meeting notes on disk (`~/Documents/Glance Meetings/*.md`) for the
/// transcript pane's history list.
enum MeetingHistory {

    struct Entry: Identifiable {
        var id: String { url.path }
        let url: URL
        let title: String       // "Meeting 2026-07-03 11.05" → cleaned
        let modified: Date
        let snippet: String     // first summary/transcript line
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Glance Meetings", isDirectory: true)
    }

    static func entries() -> [Entry] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return items
            .filter { $0.pathExtension == "md" }
            .map { url -> Entry in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return Entry(url: url,
                             title: url.deletingPathExtension().lastPathComponent,
                             modified: modified,
                             snippet: snippet(of: url))
            }
            .sorted { $0.modified > $1.modified }
    }

    /// First meaningful content line (skips headings/blank/separator lines).
    private static func snippet(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 4096)
        guard let text = String(data: head, encoding: .utf8) else { return "" }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("---") || t.hasPrefix("**[") { continue }
            return String(t.prefix(120))
        }
        return ""
    }
}
