import SwiftUI

/// First-launch tour: one page at a time, dots + Back/Continue, DS light
/// surface. Content comes from `OnboardingCatalog`; the provider page appends
/// live CLI-detection rows so the user knows whether setup is already done.
struct OnboardingView: View {
    let pages: [OnboardingPage]
    /// Detection rows for the provider page (injected so previews/tests can
    /// stub it; the default asks the real locators).
    var providerStatus: () -> [(name: String, connected: Bool, label: String)]
        = OnboardingView.liveProviderStatus
    var onFinish: () -> Void

    @State private var index = 0
    /// +1 while paging forward, -1 while paging back — drives slide direction.
    @State private var direction: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { onFinish() }
                    .buttonStyle(.plain)
                    .font(DS.Typo.label)
                    .foregroundStyle(DS.textTertiary)
                    .pointerCursor()
                    .accessibilityLabel("Skip")
            }
            .padding([.top, .horizontal], DS.Space.md)

            if pages.indices.contains(index) {
                pageBody(pages[index])
                    .id(pages[index].id)
                    .transition(pageTransition)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            footer
        }
        .frame(width: 560, height: 700)
        .background(DS.bg)
    }

    // MARK: - Page

    private func pageBody(_ page: OnboardingPage) -> some View {
        VStack(spacing: DS.Space.md) {
            Group {
                // The welcome page introduces the app, so it gets the real
                // logo; the rest are topic pages and keep their symbol.
                if page.id == "welcome" {
                    BrandMark(size: 64)
                } else {
                    ZStack {
                        Circle().fill(DS.accentSoft).frame(width: 64, height: 64)
                        Image(systemName: page.symbol)
                            .font(DS.Typo.heroIcon)
                            .foregroundStyle(DS.accentText)
                    }
                }
            }
            .padding(.top, DS.Space.xs)

            VStack(spacing: DS.Space.xs) {
                Text(page.title)
                    .font(DS.Typo.hero)
                    .foregroundStyle(DS.textPrimary)
                Text(page.subtitle)
                    .font(DS.Typo.body)
                    .foregroundStyle(DS.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }

            OnboardingIllustration.view(for: page.id)

            VStack(spacing: DS.Space.sm) {
                ForEach(page.rows, id: \.title) { row in
                    featureRow(row)
                }
            }
            .padding(.top, DS.Space.xs)

            if page.id == "provider" {
                providerStatusBox
            }
        }
        .padding(.horizontal, DS.Space.xl)
    }

    private func featureRow(_ row: OnboardingRow) -> some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.small)
                    .fill(DS.surface)
                    .frame(width: 32, height: 32)
                Image(systemName: row.symbol)
                    .font(DS.Typo.rowIcon)
                    .foregroundStyle(DS.accentText)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(DS.Typo.headline)
                    .foregroundStyle(DS.textPrimary)
                Text(row.detail)
                    .font(DS.Typo.body)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 460)
    }

    /// Live "is your CLI ready?" readout — informational only, no actions.
    private var providerStatusBox: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("ON THIS MAC")
                .font(DS.Typo.overline)
                .tracking(0.8)
                .foregroundStyle(DS.textTertiary)
            ForEach(providerStatus(), id: \.name) { entry in
                HStack(spacing: DS.Space.xs) {
                    Circle()
                        .fill(entry.connected ? DS.success : DS.warning)
                        .frame(width: 7, height: 7)
                    Text(entry.name)
                        .font(DS.Typo.label)
                        .foregroundStyle(DS.textPrimary)
                    Text(entry.label)
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.textSecondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: 460)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium)
            .strokeBorder(DS.border, lineWidth: 1))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Back") { go(-1) }
                .buttonStyle(DSSecondaryButtonStyle())
                .opacity(index == 0 ? 0 : 1)
                .disabled(index == 0)
                .accessibilityLabel("Back")

            Spacer()

            HStack(spacing: DS.Space.xs) {
                ForEach(pages.indices, id: \.self) { i in
                    Circle()
                        .fill(i == index ? DS.accentText : DS.border)
                        .frame(width: 7, height: 7)
                }
            }

            Spacer()

            Button(isLastPage ? "Get Started" : "Continue") {
                if isLastPage { onFinish() } else { go(1) }
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(isLastPage ? "Get Started" : "Continue")
        }
        .padding(DS.Space.md)
        .background(DS.surface)
        .overlay(alignment: .top) { Rectangle().fill(DS.divider).frame(height: 1) }
    }

    private var isLastPage: Bool { index >= pages.count - 1 }

    private func go(_ step: Int) {
        let next = min(max(index + step, 0), pages.count - 1)
        guard next != index else { return }
        direction = step > 0 ? 1 : -1
        // Purposeful, short, ease-out; Reduce Motion drops the animation.
        if reduceMotion {
            index = next
        } else {
            withAnimation(.easeOut(duration: 0.2)) { index = next }
        }
    }

    /// Fade + 8pt slide in the paging direction (opacity-only under Reduce
    /// Motion since the un-animated swap ignores the transition anyway).
    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .offset(x: 8 * direction).combined(with: .opacity),
            removal: .offset(x: -8 * direction).combined(with: .opacity)
        )
    }

    // MARK: - Live provider detection

    static func liveProviderStatus() -> [(name: String, connected: Bool, label: String)] {
        let claude: (Bool, String)
        if case .ok(_, let version) = ClaudeLocator.check() {
            claude = (true, "detected · \(version.split(separator: " ").first.map(String.init) ?? version)")
        } else {
            claude = (false, "not found — install from claude.com/code")
        }
        let codex: (Bool, String)
        if case .ok(_, let version) = CodexLocator.check() {
            codex = (true, "detected · \(version.split(separator: " ").first.map(String.init) ?? version)")
        } else {
            codex = (false, "not found — install Codex CLI and sign in")
        }
        return [
            (AskBackendKind.claude.displayName, claude.0, claude.1),
            (AskBackendKind.codex.displayName, codex.0, codex.1),
        ]
    }
}
