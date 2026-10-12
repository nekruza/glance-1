import AppKit
import SwiftUI

/// Read-only, selectable rich text drawn by AppKit. Used for prose runs and
/// code blocks in place of SwiftUI Text, for two reasons:
/// - one NSTextView holds a whole run of paragraphs, headings and list items,
///   so a mouse drag selects across them (SwiftUI scopes a selection to a
///   single Text, so the old per-block Texts selected one sentence at a time);
/// - SwiftUI gives a Text with styled runs (colours, bold, inline code) a
///   full-size bitmap even when it's scrolled out of view. The transcript is
///   not lazy, so a long chat with code blocks reached gigabytes.
///   NSTextView only draws what's visible.
struct SelectableText: NSViewRepresentable {
    let text: NSAttributedString
    /// Rail colour for runs tagged `.glanceQuote`.
    var quoteBar: Color = .clear

    func makeNSView(context: Context) -> MarkdownTextView {
        let view = MarkdownTextView()
        view.quoteBarColor = NSColor(quoteBar)
        view.textStorage?.setAttributedString(text)
        return view
    }

    func updateNSView(_ view: MarkdownTextView, context: Context) {
        view.quoteBarColor = NSColor(quoteBar)
        guard let storage = view.textStorage, !storage.isEqual(to: text) else { return }
        // Streaming replaces the text on every token; keep whatever the user
        // has selected so far instead of dropping it.
        let selection = view.selectedRanges
        storage.setAttributedString(text)
        let length = storage.length
        view.selectedRanges = selection.map { value in
            let r = value.rangeValue
            let loc = min(r.location, length)
            return NSValue(range: NSRange(location: loc, length: min(r.length, length - loc)))
        }
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownTextView, context: Context) -> CGSize? {
        nsView.fittingSize(width: proposal.width)
    }
}

/// Read-only, selectable, transparent text view that sizes to its content and
/// paints the blockquote rail (TextKit can't express a left border).
final class MarkdownTextView: NSTextView {
    var quoteBarColor: NSColor = .clear

    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        // Links open in the browser on click, like the old Text links.
        isAutomaticLinkDetectionEnabled = false
    }

    /// Height of the laid-out text at `width` (the full width SwiftUI offers).
    func fittingSize(width: CGFloat?) -> CGSize {
        guard let layout = layoutManager, let container = textContainer else { return .zero }
        let w = width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 10_000
        if container.size.width != w {
            container.size = NSSize(width: w, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: width == nil ? ceil(used.width) : w, height: ceil(used.height))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: fittingSize(width: bounds.width).height)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawQuoteBars()
        super.draw(dirtyRect)
    }

    private func drawQuoteBars() {
        guard let storage = textStorage, let layout = layoutManager else { return }
        quoteBarColor.setFill()
        storage.enumerateAttribute(.glanceQuote, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var bar = NSRect.null
            // Union of the lines' *used* rects so paragraph spacing above the
            // quote isn't painted as rail.
            layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
                bar = bar.union(used)
            }
            guard !bar.isNull else { return }
            let rail = NSRect(x: 0, y: bar.minY - 2, width: 3, height: bar.height + 4)
            NSBezierPath(roundedRect: rail, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

extension NSAttributedString.Key {
    /// Marks blockquote text so MarkdownTextView can draw its rail.
    static let glanceQuote = NSAttributedString.Key("GlanceQuote")
}

/// Builds the AppKit attributed string for a run of prose blocks, matching
/// the fonts, colours and vertical rhythm of the SwiftUI block views.
enum MarkdownAttributed {
    private static let indentStep: CGFloat = 16
    private static let glyphs = ["•", "◦", "▪", "·"]

    static func build(_ blocks: [MarkdownText.Block], palette: MarkdownPalette,
                      fontSize: CGFloat, scale: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: fontSize * scale)
        let text = NSColor(palette.text)
        for (i, block) in blocks.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            let start = out.length
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = i > 0 ? MarkdownText.gap(from: blocks[i - 1], to: block) : 0

            switch block {
            case .heading(let level, let t):
                if level >= 2 && palette.uppercaseLabels {
                    out.append(NSAttributedString(string: t.uppercased(), attributes: [
                        .font: NSFont.systemFont(ofSize: 11 * scale, weight: .semibold),
                        .foregroundColor: NSColor(palette.heading),
                        .kern: 0.4,
                    ]))
                } else if level >= 2 {
                    out.append(inline(t, font: .systemFont(ofSize: 13.5 * scale, weight: .semibold),
                                      color: NSColor(palette.title), palette: palette, scale: scale))
                } else {
                    let s = inline(t, font: .systemFont(ofSize: 16 * scale, weight: .semibold),
                                   color: text, palette: palette, scale: scale)
                    s.addAttribute(.kern, value: -0.2, range: NSRange(location: 0, length: s.length))
                    out.append(s)
                }

            case .bullet(let depth, let checked, let t):
                let marker: NSAttributedString
                if let checked {
                    marker = checkbox(checked, font: body, palette: palette)
                } else {
                    marker = NSAttributedString(string: glyphs[min(depth, glyphs.count - 1)], attributes: [
                        .font: body, .foregroundColor: NSColor(palette.bullet),
                    ])
                }
                listItem(marker: marker, depth: depth, style: style, into: out)
                out.append(inline(t, font: body, color: text, palette: palette, scale: scale))
                style.lineSpacing = 3

            case .ordered(let depth, let n, let t):
                let marker = NSAttributedString(string: "\(n).", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: body.pointSize, weight: .regular),
                    .foregroundColor: NSColor(palette.bullet),
                ])
                listItem(marker: marker, depth: depth, style: style, into: out)
                out.append(inline(t, font: body, color: text, palette: palette, scale: scale))
                style.lineSpacing = 3

            case .quote(let t):
                let s = inline(t, font: body, color: NSColor(palette.quoteFg), palette: palette, scale: scale)
                s.addAttribute(.glanceQuote, value: true, range: NSRange(location: 0, length: s.length))
                out.append(s)
                style.firstLineHeadIndent = 13
                style.headIndent = 13
                style.lineSpacing = 3
                // The rail extends 2pt above and below the text.
                style.paragraphSpacingBefore += 2
                style.paragraphSpacing = 2

            case .paragraph(let t):
                out.append(inline(t, font: body, color: text, palette: palette, scale: scale))
                style.lineSpacing = 4

            case .code, .draft, .table, .rule:
                assertionFailure("non-prose block in a selectable run")
            }
            out.addAttribute(.paragraphStyle, value: style,
                             range: NSRange(location: start, length: out.length - start))
        }
        return out
    }

    /// Syntax-highlighted code from SyntaxHighlighter, whose runs carry only a
    /// SwiftUI colour and (for comments) an italic font.
    static func code(_ highlighted: AttributedString, monoSize: CGFloat) -> NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: monoSize, weight: .regular)
        let italic = NSFontManager.shared.convert(mono, toHaveTrait: .italicFontMask)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        let out = NSMutableAttributedString()
        for run in highlighted.runs {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: run.font == nil ? mono : italic,
                .paragraphStyle: style,
            ]
            if let color = run.foregroundColor { attrs[.foregroundColor] = NSColor(color) }
            out.append(NSAttributedString(string: String(highlighted[run.range].characters), attributes: attrs))
        }
        return out
    }

    /// Whether `block` renders as prose inside one SelectableText.
    static func isProse(_ block: MarkdownText.Block) -> Bool {
        switch block {
        case .heading, .bullet, .ordered, .quote, .paragraph: return true
        case .code, .draft, .table, .rule: return false
        }
    }

    /// `marker<TAB>` with a hanging indent so wrapped lines align with the
    /// item text, as the SwiftUI HStack(spacing: 8) did.
    private static func listItem(marker: NSAttributedString, depth: Int,
                                 style: NSMutableParagraphStyle, into out: NSMutableAttributedString) {
        let lead = CGFloat(depth) * indentStep
        let textStart = lead + ceil(marker.size().width) + 8
        style.firstLineHeadIndent = lead
        style.headIndent = textStart
        style.tabStops = [NSTextTab(textAlignment: .left, location: textStart)]
        out.append(marker)
        out.append(NSAttributedString(string: "\t", attributes: marker.attributes(at: 0, effectiveRange: nil)))
    }

    private static func checkbox(_ checked: Bool, font: NSFont, palette: MarkdownPalette) -> NSAttributedString {
        let color = NSColor(checked ? palette.bullet : palette.heading)
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: checked ? "checkmark.square.fill" : "square",
                                   accessibilityDescription: checked ? "done" : "to do")?
            .withSymbolConfiguration(config) else {
            return NSAttributedString(string: checked ? "☑" : "☐", attributes: [.font: font, .foregroundColor: color])
        }
        // Tint by compositing over the template's alpha, so the checkmark
        // stays a see-through cutout like SwiftUI's monochrome rendering.
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - image.size.height) / 2,
                                   width: image.size.width, height: image.size.height)
        let s = NSMutableAttributedString(attachment: attachment)
        s.addAttribute(.font, value: font, range: NSRange(location: 0, length: s.length))
        return s
    }

    /// Inline emphasis / `code` / links, mapped from Foundation's Markdown
    /// presentation intents to AppKit font and colour attributes.
    static func inline(_ s: String, font: NSFont, color: NSColor,
                       palette: MarkdownPalette, scale: CGFloat) -> NSMutableAttributedString {
        let parsed = (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            var runFont = font
            if intent.contains(.code) {
                runFont = .monospacedSystemFont(ofSize: 12 * scale, weight: .regular)
                attrs[.backgroundColor] = NSColor(palette.inlineCodeBg)
            }
            if intent.contains(.stronglyEmphasized) {
                runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {
                runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask)
            }
            if intent.contains(.strikethrough) {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attrs[.link] = link
            }
            attrs[.font] = runFont
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
        }
        return out
    }
}
