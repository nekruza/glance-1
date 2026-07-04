import SwiftUI

/// Colors for MarkdownText rendering. `.dark` matches the overlay's original
/// values exactly; `.light` maps to the DS tokens for the task surfaces.
struct MarkdownPalette {
    let bullet: Color
    let heading: Color
    let codeFg: Color
    let codeBg: Color
    let codeBorder: Color

    static let dark = MarkdownPalette(
        bullet: Theme.accent,
        heading: Theme.muted,
        codeFg: Color(red: 0xdf/255, green: 0xe4/255, blue: 0xf0/255),
        codeBg: Theme.codeBg,
        codeBorder: Theme.glassBorder)

    static let light = MarkdownPalette(
        bullet: DS.accentText,
        heading: DS.textSecondary,
        codeFg: DS.textPrimary,
        codeBg: DS.codeBg,
        codeBorder: DS.border)
}

/// FR11 subset Markdown renderer for streamed answers. Required: fenced code
/// blocks (monospaced, no syntax highlighting), lists, headings, inline
/// emphasis / `code`. Anything else degrades to plain text — acceptable per FR11.
///
/// Built to tolerate *partial* input (streaming): an unclosed ``` fence renders
/// as code-in-progress rather than breaking.
struct MarkdownText: View {
    let text: String
    /// Rendering palette — defaults to the overlay's dark glass; the light
    /// task surfaces pass `.light`.
    var palette: MarkdownPalette = .dark

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                block.view(palette)
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

        @ViewBuilder func view(_ palette: MarkdownPalette) -> some View {
            switch self {
            case .heading(let level, let t):
                if level >= 2 {
                    // Design: uppercase, tracked, muted section labels.
                    Text(t.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(palette.heading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                } else {
                    Text(inline(t))
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .bullet(let t):
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(palette.bullet)
                    Text(inline(t)).fixedSize(horizontal: false, vertical: true)
                }
            case .ordered(let n, let t):
                HStack(alignment: .top, spacing: 8) {
                    Text("\(n).").foregroundStyle(palette.bullet).monospacedDigit()
                    Text(inline(t)).fixedSize(horizontal: false, vertical: true)
                }
            case .code(let code):
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.codeFg)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(palette.codeBg))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.codeBorder, lineWidth: 1))
            case .paragraph(let t):
                Text(inline(t))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
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
