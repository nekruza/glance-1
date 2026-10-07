import SwiftUI

/// The `/` command menu under the input, after Claude Code's prompt
/// autocomplete: monospaced name column, description beside it, matched
/// characters bold, the highlighted row in the accent color.
struct SlashCommandMenu: View {
    let matches: [SlashMatch]
    let selection: Int
    /// The CLI's catalog hasn't arrived yet (only Glance's own commands show).
    let loading: Bool
    let textScale: CGFloat
    let onPick: (SlashCommand) -> Void

    static let maxVisibleRows = 8
    private var rowHeight: CGFloat { 26 * textScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: matches.count > Self.maxVisibleRows) {
                    // Lazy: an empty query lists ~190 commands; only the
                    // visible rows should cost layout per keystroke.
                    LazyVStack(spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.element.command.name) { i, match in
                            row(match, selected: i == selection)
                                .id(match.command.name)
                        }
                    }
                }
                .frame(height: rowHeight * CGFloat(min(matches.count, Self.maxVisibleRows)))
                .onChange(of: selection) { _, i in
                    guard matches.indices.contains(i) else { return }
                    proxy.scrollTo(matches[i].command.name)
                }
            }
            hint
        }
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.glassBorder, lineWidth: 1))
        .padding(.horizontal, 14).padding(.bottom, 8)
    }

    private func row(_ match: SlashMatch, selected: Bool) -> some View {
        let base = selected ? Theme.accent : Theme.fg.opacity(0.88)
        let dim = selected ? Theme.accent.opacity(0.9) : Theme.muted
        return HStack(spacing: 14) {
            Text(highlighted("/" + match.command.name,
                             offsets: Set(match.nameHighlights.map { $0 + 1 }), // +1: the "/"
                             color: base, strong: selected ? Theme.accent : Theme.fg))
                .font(.system(size: 12.5 * textScale, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 230 * textScale, alignment: .leading)
            Text(highlighted(match.command.description,
                             offsets: Set(match.descriptionHighlight.map(Array.init) ?? []),
                             color: dim, strong: selected ? Theme.accent : Theme.fg))
                .font(.system(size: 12 * textScale))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: rowHeight)
        .background(selected ? Theme.accent.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onPick(match.command) }
        .help(match.command.argumentHint.flatMap { $0.isEmpty ? nil : "/\(match.command.name) \($0)" } ?? "")
    }

    private var hint: some View {
        HStack {
            if loading {
                Text("Loading Claude Code commands…")
            }
            Spacer()
            Text("↑↓ select · tab complete · ↩ run · esc close")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.faint)
        .padding(.horizontal, 12).padding(.top, 5)
    }

    /// Bold + full-strength color on the matched characters, as the CLI does.
    /// Built from runs (not per character): the menu re-renders every keystroke.
    private func highlighted(_ text: String, offsets: Set<Int>, color: Color,
                             strong: Color) -> AttributedString {
        var out = AttributedString()
        var run = ""
        var runIsMatch = false
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            piece.foregroundColor = runIsMatch ? strong : color
            if runIsMatch { piece.inlinePresentationIntent = .stronglyEmphasized }
            out += piece
            run = ""
        }
        for (i, ch) in text.enumerated() {
            let isMatch = offsets.contains(i)
            if isMatch != runIsMatch { flush(); runIsMatch = isMatch }
            run.append(ch)
        }
        flush()
        return out
    }
}
