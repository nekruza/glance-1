import SwiftUI
import AppKit

/// The Glance logo, for the places that stand for the app itself — the
/// onboarding welcome page and the About pane.
///
/// The image is `GlanceLogo.png`, which `Scripts/build-app.sh` copies out of
/// `assets/logo.png` alongside the generated `Glance.icns`, so the PNG in the
/// repo stays the single source of truth for both.
///
/// Falls back to the `sparkle` treatment when no bundle resource is present —
/// unit tests and a bare `swift run` execute outside the assembled .app, and a
/// missing logo should never be a crash or an empty hole in the UI.
///
/// Deliberately *not* used for the menu-bar item or the ask affordances: those
/// stay on the `sparkle` symbol (see the note in `StatusItemController`).
struct BrandMark: View {

    /// Rendered edge length in points. The source art is square.
    let size: CGFloat

    var body: some View {
        Group {
            if let logo = Self.logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    Circle().fill(DS.accentSoft)
                    Image(systemName: "sparkle")
                        .font(.system(size: size * 0.42, weight: .medium))
                        .foregroundStyle(DS.accentText)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Glance")
    }

    /// Loaded once — this reads from disk, and the mark renders on every
    /// onboarding page turn.
    private static let logo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "GlanceLogo", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}
