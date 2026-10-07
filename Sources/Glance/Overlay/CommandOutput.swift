import Foundation

/// Structure recovered from a Claude CLI command's plain-text output
/// (`/usage`, `/model`, `/compact`…), which headless mode prints as the text
/// its terminal UI would lay out. Rendered terminal-style by
/// `CommandOutputView` instead of through Markdown, which would collapse its
/// single line breaks and indentation into one paragraph.
enum CommandOutput {

    enum Line: Equatable {
        case blank
        /// Section heading: an unindented line that leads straight into more.
        case title(String)
        case text(String, indent: Int)
        /// "Current session: 36% used · resets …" → a usage bar, as the CLI draws.
        case meter(label: String, percent: Int, detail: String)
    }

    static func parse(_ output: String) -> [Line] {
        let raw = output.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var lines: [Line] = []
        for (i, rawLine) in raw.enumerated() {
            let body = rawLine.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else {
                if let last = lines.last, last != .blank { lines.append(.blank) }
                continue
            }
            let indent = rawLine.prefix { $0 == " " }.count
            if let meter = meter(body) {
                lines.append(meter)
            } else if indent == 0, let next = raw.dropFirst(i + 1).first,
                      !next.trimmingCharacters(in: .whitespaces).isEmpty,
                      meter(next.trimmingCharacters(in: .whitespaces)) == nil {
                lines.append(.title(body))
            } else {
                lines.append(.text(body, indent: indent))
            }
        }
        while lines.last == .blank { lines.removeLast() }
        return lines
    }

    /// Real Markdown (e.g. `/context`'s tables) keeps the Markdown renderer.
    static func looksLikeMarkdown(_ output: String) -> Bool {
        if output.contains("```") || output.contains("**") { return true }
        return output.components(separatedBy: "\n").contains { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            return l.hasPrefix("#") || l.hasPrefix("|") || l.hasPrefix("- ") || l.hasPrefix("* ")
        }
    }

    // "Label: 36% used · resets Oct 7 at 4:59pm (Europe/London)"
    private static func meter(_ line: String) -> Line? {
        guard let colon = line.range(of: ": "),
              let used = line.range(of: "% used", range: colon.upperBound..<line.endIndex),
              let percent = Int(line[colon.upperBound..<used.lowerBound]) else { return nil }
        let label = String(line[..<colon.lowerBound])
        var detail = line[used.upperBound...].trimmingCharacters(in: .whitespaces)
        if detail.hasPrefix("·") { detail = detail.dropFirst().trimmingCharacters(in: .whitespaces) }
        if let first = detail.first { detail = first.uppercased() + detail.dropFirst() }
        return .meter(label: label, percent: min(max(percent, 0), 100), detail: detail)
    }
}
