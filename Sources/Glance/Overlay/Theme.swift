import SwiftUI

/// Frozen design tokens from screens/ (Neutral Modern, dark-glass overlay).
/// Values sampled from 01-overlay-idle.html / 02-overlay-answer.html.
enum Theme {
    // Accent
    /// User-tunable in Settings (default #06C167, Uber Eats green).
    static var accent: Color { Preferences.shared.accentColor }

    // Dark-glass surface
    static let glassTint = Color(red: 22/255, green: 24/255, blue: 29/255)     // rgba(22,24,29,·)
    static let glassBorder = Color.white.opacity(0.12)
    static let glassBorderHi = Color.white.opacity(0.22)
    static let field = Color.white.opacity(0.06)
    static let codeBg = Color(red: 10/255, green: 12/255, blue: 16/255).opacity(0.7)

    // Foreground scale (#f4f5f7)
    static let fg = Color(red: 0xf4/255, green: 0xf5/255, blue: 0xf7/255)
    static let muted = fg.opacity(0.56)
    static let faint = fg.opacity(0.34)

    // Semantic
    static let success = Color(red: 0x5f/255, green: 0xd0/255, blue: 0x8a/255)
    static let danger = Color(red: 0xff/255, green: 0x6b/255, blue: 0x6b/255)

    // Geometry / motion
    static let radius: CGFloat = 18
    static let overlayWidth: CGFloat = 640
    static let transcriptPaneWidth: CGFloat = 300
    static let popAnimation = Animation.spring(response: 0.28, dampingFraction: 0.82)
}
