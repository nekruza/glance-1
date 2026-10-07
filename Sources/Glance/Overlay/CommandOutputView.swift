import SwiftUI

/// Terminal-style rendering of a Claude CLI command's plain-text output, so
/// /usage, /model, /compact… read as they do in Claude Code: monospaced,
/// line breaks and indentation kept, section titles bold, usage meters drawn
/// as bars.
struct CommandOutputView: View {
    let text: String
    let textScale: CGFloat

    private var fontSize: CGFloat { 12.5 * textScale }
    /// Monospaced advance, for indenting wrapped lines as a whole.
    private var charWidth: CGFloat { fontSize * 0.6 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(CommandOutput.parse(text).enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
        .font(.system(size: fontSize, design: .monospaced))
        .foregroundStyle(Theme.fg.opacity(0.9))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func lineView(_ line: CommandOutput.Line) -> some View {
        switch line {
        case .blank:
            Color.clear.frame(height: fontSize * 0.7)
        case .title(let s):
            Text(inline(s)).fontWeight(.bold).foregroundStyle(Theme.fg)
                .padding(.top, 2)
        case .text(let s, let indent):
            Text(inline(s))
                .foregroundStyle(indent > 0 ? Theme.fg.opacity(0.78) : Theme.fg.opacity(0.9))
                .padding(.leading, CGFloat(indent) * charWidth)
                .fixedSize(horizontal: false, vertical: true)
        case .meter(let label, let percent, let detail):
            VStack(alignment: .leading, spacing: 3) {
                Text(label).fontWeight(.bold).foregroundStyle(Theme.fg)
                HStack(spacing: 10) {
                    meterBar(percent)
                    Text("\(percent)% used")
                }
                Text(detail).foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 5)
        }
    }

    private func meterBar(_ percent: Int) -> some View {
        let width: CGFloat = 300 * textScale
        return ZStack(alignment: .leading) {
            Rectangle().fill(Theme.accent.opacity(0.22))
            Rectangle().fill(Theme.accent)
                .frame(width: width * CGFloat(percent) / 100)
        }
        .frame(width: width, height: 13 * textScale)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }

    /// Inline `code` / emphasis inside a line, whitespace kept.
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
