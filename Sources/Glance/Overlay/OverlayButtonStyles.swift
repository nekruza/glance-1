import SwiftUI

/// Icon / text-icon button for the overlay chrome: invisible at rest, soft
/// fill on hover, tiny press-down on click. Labels must NOT set their own
/// foreground style — the style owns it so hover can brighten the glyph.
struct OverlayIconButtonStyle: ButtonStyle {
    var minWidth: CGFloat = 28
    var height: CGFloat = 28
    var corner: CGFloat = 8
    /// Pins the glyph colour (e.g. the accent when a toggle is on). Nil =
    /// muted at rest, full foreground on hover.
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, style: self)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyle.Configuration
        let style: OverlayIconButtonStyle
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(style.tint ?? (hovering ? Theme.fg : Theme.muted))
                .frame(minWidth: style.minWidth, minHeight: style.height)
                .background(
                    RoundedRectangle(cornerRadius: style.corner, style: .continuous)
                        .fill(Color.white.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0))
                )
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering = $0 }
                .pointerCursor()
        }
    }
}

/// Follow-up suggestion chip: outlined capsule that lifts on hover.
struct OverlayChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(Theme.fg.opacity(hovering ? 1 : 0.8))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.12 : hovering ? 0.09 : 0.05)))
                .overlay(Capsule().strokeBorder(hovering ? Theme.glassBorderHi : Theme.glassBorder, lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
                .pointerCursor()
        }
    }
}
