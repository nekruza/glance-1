import SwiftUI

/// Fenced code block: a slim header (language label + Copy) over a
/// syntax-highlighted body. The header is a real row, not a chip floating over
/// the first line, so Copy never covers code.
struct CodeBlockView: View {
    let language: String?
    let code: String
    let palette: MarkdownPalette

    private static let monoSize: CGFloat = 11.5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language?.lowercased() ?? "code")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(palette.heading.opacity(0.85))
                Spacer(minLength: 0)
                CopyChip(helpText: "Copy code", palette: palette) {
                    // Code is code: plain text only, exactly as written.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 6)
            .background(palette.tableHeaderBg)

            Rectangle().fill(palette.rule).frame(height: 1)

            Text(SyntaxHighlighter.highlight(code, language: language,
                                             theme: palette.syntax, monoSize: Self.monoSize))
                .font(.system(size: Self.monoSize, design: .monospaced))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.codeBg))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(palette.codeBorder, lineWidth: 1))
    }
}
