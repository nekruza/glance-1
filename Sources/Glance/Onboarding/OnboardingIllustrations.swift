import SwiftUI

/// Miniature "screenshots" of the app's real surfaces for the tour, drawn
/// with the app's own design tokens (Theme for the dark ask overlay, DS for
/// the light task board) so they always match the shipping UI — no bundled
/// PNGs to go stale. Decorative only; hidden from accessibility.
enum OnboardingIllustration {

    /// Illustration for a tour page, or nil-equivalent EmptyView.
    @ViewBuilder
    static func view(for pageID: String) -> some View {
        switch pageID {
        case "welcome": MenuBarMock()
        case "ask": OverlayMock()
        case "tasks": TaskBoardMock()
        default: EmptyView()
        }
    }
}

/// The macOS menu bar with Glance's sparkle icon highlighted.
private struct MenuBarMock: View {
    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Spacer()
            Image(systemName: "sparkle")
                .font(DS.Typo.rowIcon)
                .foregroundStyle(DS.accentText)
                .padding(.horizontal, DS.Space.xs)
                .padding(.vertical, 3)
                .background(Capsule().fill(DS.accentSoft))
            Image(systemName: "wifi").font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
            Image(systemName: "battery.75percent").font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
            Text("11:42").font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
        }
        .padding(.horizontal, DS.Space.sm)
        .frame(width: 300, height: 28)
        .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.small).strokeBorder(DS.border, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// The dark-glass ask overlay mid-answer, in miniature (Theme tokens).
private struct OverlayMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "camera.viewfinder")
                    .font(DS.Typo.caption)
                    .foregroundStyle(Theme.muted)
                Text("Why is this build failing?")
                    .font(DS.Typo.label)
                    .foregroundStyle(Theme.fg)
                Spacer(minLength: 0)
            }
            .padding(DS.Space.xs)
            .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(Theme.field))

            // Streaming answer, skeleton style.
            skeleton(width: 250)
            skeleton(width: 210)
            skeleton(width: 120)
        }
        .padding(DS.Space.sm)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(Theme.glassTint))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium)
            .strokeBorder(Theme.glassBorder, lineWidth: 1))
        .accessibilityHidden(true)
    }

    private func skeleton(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Theme.fg.opacity(0.22))
            .frame(width: width, height: 7)
    }
}

/// Two task-board cards with source accent strips, in miniature (DS tokens).
private struct TaskBoardMock: View {
    var body: some View {
        HStack(spacing: DS.Space.sm) {
            card(source: .jira, title: "Fix login redirect", dot: DS.danger)
            card(source: .slack, title: "Reply to #support", dot: DS.textTertiary)
        }
        .padding(DS.Space.sm)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.surface))
        .accessibilityHidden(true)
    }

    private func card(source: TaskSource, title: String, dot: Color) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(DS.sourceAccent(source))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.xxs) {
                    Circle().fill(dot).frame(width: 5, height: 5)
                    Text(title).font(DS.Typo.caption).foregroundStyle(DS.textPrimary)
                }
                RoundedRectangle(cornerRadius: 3)
                    .fill(DS.border)
                    .frame(width: 90, height: 6)
            }
            .padding(DS.Space.xs)
        }
        .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.bg))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.small).strokeBorder(DS.border, lineWidth: 1))
    }
}
