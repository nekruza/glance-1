import SwiftUI

/// Colors for MarkdownText rendering. `.dark` matches the overlay's original
/// values exactly; `.light` maps to the DS tokens for the task surfaces.
struct MarkdownPalette {
    let bullet: Color
    let heading: Color
    let codeFg: Color
    let codeBg: Color
    let codeBorder: Color
    /// Left rail on a blockquote.
    let quoteBar: Color
    /// Body text inside a blockquote — a step back from primary.
    let quoteFg: Color
    /// Thematic break (`---`).
    let rule: Color
    /// Chip behind `inline code`.
    let inlineCodeBg: Color

    static let dark = MarkdownPalette(
        bullet: Theme.accent,
        heading: Theme.muted,
        codeFg: Color(red: 0xdf/255, green: 0xe4/255, blue: 0xf0/255),
        codeBg: Theme.codeBg,
        codeBorder: Theme.glassBorder,
        quoteBar: Theme.accent.opacity(0.6),
        quoteFg: Theme.fg.opacity(0.82),
        rule: Theme.glassBorder,
        inlineCodeBg: Color.white.opacity(0.09))

    static let light = MarkdownPalette(
        bullet: DS.accentText,
        heading: DS.textSecondary,
        codeFg: DS.textPrimary,
        codeBg: DS.codeBg,
        codeBorder: DS.border,
        quoteBar: DS.accentText.opacity(0.5),
        quoteFg: DS.textSecondary,
        rule: DS.divider,
        inlineCodeBg: DS.surfaceHover)
}

/// FR11 subset Markdown renderer for streamed answers. Required: fenced code
/// blocks (monospaced, no syntax highlighting), lists, headings, inline
/// emphasis / `code`. Also handles blockquotes, thematic breaks, task lists and
/// nested lists so their syntax never leaks through as literal characters.
///
/// Built to tolerate *partial* input (streaming): an unclosed ``` fence renders
/// as code-in-progress rather than breaking.
struct MarkdownText: View {
    let text: String
    /// Rendering palette — defaults to the overlay's dark glass; the light
    /// task surfaces pass `.light`.
    var palette: MarkdownPalette = .dark

    var body: some View {
        let blocks = Self.parse(text)
        // spacing: 0 — vertical rhythm is per-pair (see `gap`), so list items
        // sit tight together while headings and quotes get real breathing room.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                block.view(palette)
                    .padding(.top, Self.gap(from: i > 0 ? blocks[i - 1] : nil, to: block))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Block model

    enum Block {
        case heading(level: Int, text: String)
        case bullet(depth: Int, checked: Bool?, text: String)
        case ordered(depth: Int, number: String, text: String)
        case code(String)
        case quote(String)
        case paragraph(String)
        case rule

        /// Nesting indent per list level.
        private static let indentStep: CGFloat = 16
        private static let glyphs = ["•", "◦", "▪", "·"]

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
                } else {
                    Text(Self.inline(t, palette))
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }

            case .bullet(let depth, let checked, let t):
                HStack(alignment: .top, spacing: 8) {
                    if let checked {
                        // SF Symbols, not the ☐/☑ glyphs — those render thin
                        // and sit off the text baseline.
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .foregroundStyle(checked ? palette.bullet : palette.heading)
                            .imageScale(.medium)
                    } else {
                        Text(Self.glyphs[min(depth, Self.glyphs.count - 1)])
                            .foregroundStyle(palette.bullet)
                    }
                    Text(Self.inline(t, palette))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(depth) * Self.indentStep)

            case .ordered(let depth, let n, let t):
                HStack(alignment: .top, spacing: 8) {
                    Text("\(n).").foregroundStyle(palette.bullet).monospacedDigit()
                    Text(Self.inline(t, palette))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(depth) * Self.indentStep)

            case .code(let code):
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.codeFg)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(palette.codeBg))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.codeBorder, lineWidth: 1))

            case .quote(let t):
                // A quote reads as quoted material because of the rail and the
                // colour — never because we printed a ">" at the user.
                // The rail is an overlay, not an HStack sibling: a sibling with
                // maxHeight .infinity collapses under fixedSize, leaving a stub.
                Text(Self.inline(t, palette))
                    .lineSpacing(3)
                    .foregroundStyle(palette.quoteFg)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                    .padding(.leading, 13)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(palette.quoteBar)
                            .frame(width: 3)
                    }

            case .paragraph(let t):
                Text(Self.inline(t, palette))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

            case .rule:
                Rectangle()
                    .fill(palette.rule)
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
            }
        }

        /// Inline emphasis / `code` via Foundation's Markdown parser, scoped to a
        /// single block so streaming can't corrupt block structure. Runs tagged
        /// `.code` get a monospaced face and a chip background, which Text does
        /// not apply on its own.
        static func inline(_ s: String, _ palette: MarkdownPalette) -> AttributedString {
            var out = (try? AttributedString(
                markdown: s,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(s)

            // Collect first: mutating `out` while iterating `out.runs` is invalid.
            let codeRuns = out.runs.compactMap { run -> Range<AttributedString.Index>? in
                (run.inlinePresentationIntent?.contains(.code) ?? false) ? run.range : nil
            }
            for range in codeRuns {
                out[range].font = .system(size: 12.5, design: .monospaced)
                out[range].backgroundColor = palette.inlineCodeBg
            }
            return out
        }
    }

    // MARK: - Vertical rhythm

    /// Space above `next`, given what precedes it. Sibling list items hug;
    /// section headings and set-apart blocks get air.
    static func gap(from prev: Block?, to next: Block) -> CGFloat {
        guard let prev else { return 0 }
        switch (prev, next) {
        case (.bullet, .bullet), (.ordered, .ordered),
             (.bullet, .ordered), (.ordered, .bullet):
            return 5
        case (_, .heading(let level, _)):
            return level >= 2 ? 20 : 16
        case (.heading, _):
            return 8
        case (_, .rule), (.rule, _):
            return 16
        case (_, .code), (.code, _),
             (_, .quote), (.quote, _):
            return 12
        default:
            return 10
        }
    }

    // MARK: - Parser

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var inCode = false
        var codeLines: [String] = []
        var paragraph: [String] = []
        var quote: [String] = []
        /// Stack of leading-indent widths seen in the current list run; its
        /// depth is the nesting level. Works for 2- and 4-space indents alike.
        var indents: [Int] = []

        func flushCode() {
            blocks.append(.code(codeLines.joined(separator: "\n")))
            codeLines.removeAll()
        }
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            // Soft-wrapped lines are ONE paragraph, per Markdown.
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: " ")))
            quote.removeAll()
        }
        func flushText() { flushParagraph(); flushQuote() }
        func depth(for indent: Int) -> Int {
            while let last = indents.last, last > indent { indents.removeLast() }
            if indents.last == nil || indents.last! < indent { indents.append(indent) }
            return min(indents.count - 1, 3)
        }

        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode { flushCode(); inCode = false }
                else { flushText(); indents.removeAll(); inCode = true }
                continue
            }
            if inCode { codeLines.append(rawLine); continue }

            if trimmed.isEmpty { flushText(); indents.removeAll(); continue }

            if isRule(trimmed) {
                flushText(); indents.removeAll()
                blocks.append(.rule)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph(); indents.removeAll()
                var body = Substring(trimmed)
                // Strip the marker (and nested markers) plus one space each.
                while body.hasPrefix(">") {
                    body = body.dropFirst()
                    if body.hasPrefix(" ") { body = body.dropFirst() }
                }
                if body.isEmpty { flushQuote() } else { quote.append(String(body)) }
                continue
            }
            flushQuote()

            if let (level, rest) = heading(trimmed) {
                flushParagraph(); indents.removeAll()
                blocks.append(.heading(level: level, text: rest))
                continue
            }

            if let item = listItem(trimmed) {
                flushParagraph()
                let d = depth(for: leadingIndent(rawLine))
                if item.ordered {
                    blocks.append(.ordered(depth: d, number: item.number, text: item.text))
                } else if let (checked, body) = checkbox(item.text) {
                    blocks.append(.bullet(depth: d, checked: checked, text: body))
                } else {
                    blocks.append(.bullet(depth: d, checked: nil, text: item.text))
                }
                continue
            }

            indents.removeAll()
            paragraph.append(trimmed)
        }

        flushText()
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

    /// `---`, `***`, `___` (3+ of one char, spaces allowed between).
    private static func isRule(_ s: String) -> Bool {
        guard let first = s.first, first == "-" || first == "*" || first == "_" else { return false }
        let dense = s.filter { !$0.isWhitespace }
        return dense.count >= 3 && dense.allSatisfy { $0 == first }
    }

    private static func leadingIndent(_ s: String) -> Int {
        var n = 0
        for ch in s {
            if ch == " " { n += 1 }
            else if ch == "\t" { n += 4 }
            else { break }
        }
        return n
    }

    private static func listItem(_ s: String) -> (ordered: Bool, number: String, text: String)? {
        if let first = s.first, first == "-" || first == "*" || first == "+" {
            let rest = s.dropFirst()
            guard rest.hasPrefix(" ") else { return nil }
            let body = rest.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { return nil }
            return (false, "", body)
        }
        let digits = s.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let after = s.dropFirst(digits.count)
        guard let sep = after.first, sep == "." || sep == ")" else { return nil }
        // A space after the separator is required, else "3.14 is pi" parses as
        // an ordered item numbered 3.
        let afterSep = after.dropFirst()
        guard afterSep.hasPrefix(" ") else { return nil }
        let body = afterSep.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        return (true, String(digits), body)
    }

    /// `[ ] todo` / `[x] done` following a bullet marker.
    private static func checkbox(_ s: String) -> (Bool, String)? {
        let lower = s.lowercased()
        if lower.hasPrefix("[ ] ") { return (false, String(s.dropFirst(4))) }
        if lower.hasPrefix("[x] ") { return (true, String(s.dropFirst(4))) }
        return nil
    }
}
