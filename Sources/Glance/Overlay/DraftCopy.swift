import AppKit

/// Pasteboard payload for a copied draft: RTF so Slack/Mail keep bold and
/// links, plus a plain-text fallback with the markdown syntax stripped.
///
/// AttributedString(markdown:) emits *presentation intents* (bold = an
/// "emphasized" flag), which SwiftUI Text resolves at render time — but the
/// RTF writer knows nothing about intents, so they must be resolved into
/// concrete NSFonts here or the rich copy silently loses its formatting.
enum DraftCopy {

    /// The draft rendered to an attributed string at a neutral 13pt system
    /// font. Inline styles (bold, italic, links, inline code) are resolved;
    /// block syntax is left as written — drafts are prose, and a stray "- "
    /// should paste exactly as the model wrote it.
    static func attributedString(for markdown: String) -> NSAttributedString {
        let parsed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)

        let base = NSFont.systemFont(ofSize: 13)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let text = String(parsed.characters[run.range])
            let intents = run.inlinePresentationIntent ?? []
            var font = intents.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                : base
            if intents.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intents.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: font]
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }

    /// Writes both representations in one declaration. NSAttributedString's
    /// NSPasteboardWriting provides RTF; the plain string is set explicitly —
    /// some targets read .string only.
    static func write(_ markdown: String, to pasteboard: NSPasteboard = .general) {
        let rich = attributedString(for: markdown)
        pasteboard.clearContents()
        pasteboard.writeObjects([rich])
        pasteboard.setString(rich.string, forType: .string)
    }
}
