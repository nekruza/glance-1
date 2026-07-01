import SwiftUI

/// FR11 subset Markdown renderer for streamed answers. Required: fenced code
/// blocks (monospaced, no syntax highlighting), lists, headings, inline
/// emphasis / `code`. Anything else degrades to plain text — acceptable per FR11.
///
/// Built to tolerate *partial* input (streaming): an unclosed ``` fence renders
/// as code-in-progress rather than breaking.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                block.view
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Block model

    enum Block {
        case heading(level: Int, text: String)
        case bullet(text: String)
        case ordered(number: String, text: String)
        case code(String)
        case paragraph(String)

        @ViewBuilder var view: some View {
            switch self {
            case .heading(let level, let t):
                Text(inline(t))
                    .font(.system(size: headingSize(level), weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            case .bullet(let t):
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    Text(inline(t)).fixedSize(horizontal: false, vertical: true)
                }
            case .ordered(let n, let t):
                HStack(alignment: .top, spacing: 6) {
                    Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                    Text(inline(t)).fixedSize(horizontal: false, vertical: true)
                }
            case .code(let code):
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.28)))
            case .paragraph(let t):
                Text(inline(t))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }

        private func headingSize(_ level: Int) -> CGFloat {
            switch level { case 1: return 20; case 2: return 17; default: return 15 }
        }

        /// Inline emphasis / `code` via Foundation's Markdown parser, scoped to a
        /// single line so streaming can't corrupt block structure.
        private func inline(_ s: String) -> AttributedString {
            (try? AttributedString(markdown: s,
                                   options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(s)
        }
    }

    // MARK: - Parser

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var inCode = false
        var codeLines: [String] = []

        func flushCode() {
            blocks.append(.code(codeLines.joined(separator: "\n")))
            codeLines.removeAll()
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode { flushCode(); inCode = false }
                else { inCode = true }
                continue
            }
            if inCode { codeLines.append(line); continue }

            if trimmed.isEmpty { continue }

            if let (level, rest) = heading(trimmed) {
                blocks.append(.heading(level: level, text: rest))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(.bullet(text: String(trimmed.dropFirst(2))))
            } else if let (num, rest) = ordered(trimmed) {
                blocks.append(.ordered(number: num, text: rest))
            } else {
                blocks.append(.paragraph(trimmed))
            }
        }
        if inCode && !codeLines.isEmpty { flushCode() } // partial stream: show it
        return blocks
    }

    private static func heading(_ s: String) -> (Int, String)? {
        var level = 0
        var idx = s.startIndex
        while idx < s.endIndex, s[idx] == "#", level < 6 {
            level += 1; idx = s.index(after: idx)
        }
        guard level > 0, idx < s.endIndex, s[idx] == " " else { return nil }
        return (level, String(s[s.index(after: idx)...]))
    }

    private static func ordered(_ s: String) -> (String, String)? {
        let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let num = parts.first,
              num.allSatisfy(\.isNumber), !num.isEmpty else { return nil }
        let rest = parts[1].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return (String(num), rest)
    }
}
