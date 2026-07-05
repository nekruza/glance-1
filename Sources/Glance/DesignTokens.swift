import SwiftUI

/// Design tokens for the light app surfaces (Tasks window: board, detail,
/// settings). The dark ask-overlay keeps its own `Theme` — never mix the two.
/// All colors, spacing, radii, and fonts for the light surfaces live here;
/// views must not hard-code hex values or point sizes.
enum DS {

    // MARK: - Colors

    static let bg = Color(hexRGB: "FFFFFF")!
    static let surface = Color(hexRGB: "F6F7F9")!
    static let surfaceHover = Color(hexRGB: "EFF1F4")!
    static let border = Color(hexRGB: "E3E6EA")!
    static let divider = Color(hexRGB: "ECEEF1")!

    static let textPrimary = Color(hexRGB: "141619")!
    static let textSecondary = Color(hexRGB: "5C6570")!
    static let textTertiary = Color(hexRGB: "9AA1AB")!

    /// User-tunable in Settings (default #66E194 mint). Accent is for primary
    /// buttons, selected states, progress, and small badges ONLY — never
    /// large surfaces, and never as text on white (use `accentText`).
    static var accent: Color { Preferences.shared.accentColor }
    static var accentSoft: Color { accent.opacity(0.14) }
    /// Accent darkened for legible text/icons on white — raw mint fails
    /// contrast against #FFFFFF.
    static var accentText: Color {
        guard let c = NSColor(accent).usingColorSpace(.sRGB) else { return accent }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(nsColor: NSColor(hue: h, saturation: min(s * 1.25, 1),
                                      brightness: b * 0.62, alpha: a))
    }

    static let success = Color(hexRGB: "1E9E5F")!
    static let successSoft = success.opacity(0.12)
    static let warning = Color(hexRGB: "B45309")!
    static let warningSoft = Color(hexRGB: "F59E0B")!.opacity(0.12)
    static let danger = Color(hexRGB: "D5382F")!
    static let dangerSoft = danger.opacity(0.10)

    static let codeBg = Color(hexRGB: "F6F8FA")!

    /// Canvas dot-grid dots.
    static let dot = border

    /// Priority indicator dot on canvas cards (matches the mockup: P0 red,
    /// P1 amber, P2/P3 quiet gray).
    static func priorityDot(_ p: TaskPriority) -> Color {
        switch p {
        case .p0: return danger
        case .p1: return Color(hexRGB: "F59E0B")!
        case .p2, .p3: return textTertiary
        }
    }

    // MARK: - Motion (gate every use behind accessibilityReduceMotion)

    /// Default playful spring — card drops, reflows, meter fills.
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.75)
    /// Snappier pop — checkbox, new-card pop-in.
    static let pop = Animation.spring(response: 0.25, dampingFraction: 0.6)

    // MARK: - Elevation

    enum Shadow {
        static let card = Color.black.opacity(0.07)
        static let cardRadius: CGFloat = 8
        static let cardY: CGFloat = 2
        static let cardHoverRadius: CGFloat = 14
        static let cardHoverY: CGFloat = 5
    }

    // MARK: - Spacing (8pt grid)

    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    // MARK: - Corner radii

    enum Radius {
        static let small: CGFloat = 6   // fields, chips, segments
        static let medium: CGFloat = 10 // cards, gate boxes
        static let large: CGFloat = 14  // reserved (hero containers)
    }

    // MARK: - Typography (the only point sizes on the light surfaces)

    enum Typo {
        static let title = Font.system(size: 17, weight: .semibold)
        static let headline = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13)
        static let label = Font.system(size: 12, weight: .medium)
        static let caption = Font.system(size: 11)
        /// Add `.tracking(0.8)` and uppercase at the call site.
        static let overline = Font.system(size: 10, weight: .semibold)
        static let mono = Font.system(size: 11, design: .monospaced)
    }
}

// MARK: - Button styles

/// The one primary action per screen: accent fill, near-black label.
struct DSPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Typo.label)
            .foregroundStyle(isEnabled ? DS.textPrimary : DS.textTertiary)
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small)
                    .fill(isEnabled
                          ? (configuration.isPressed ? DS.accent.opacity(0.75) : DS.accent)
                          : DS.surface)
            )
    }
}

/// Neutral bordered button: white, 1px border, hover fill.
struct DSSecondaryButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Typo.label)
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small)
                    .fill(configuration.isPressed || hovering ? DS.surfaceHover : DS.bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.small)
                    .strokeBorder(DS.border, lineWidth: 1)
            )
            .onHover { hovering = $0 }
    }
}

// MARK: - Field chrome

/// Shared chrome for TextField/TextEditor: white, 1px border, accent focus ring.
struct DSFieldChrome: ViewModifier {
    var focused: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(DS.Space.xs)
            .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.bg))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.small)
                    .strokeBorder(focused ? DS.accent : DS.border, lineWidth: 1)
            )
    }
}

extension View {
    func dsField(focused: Bool = false) -> some View {
        modifier(DSFieldChrome(focused: focused))
    }
}

// MARK: - Badge

/// Small capsule badge: soft tint background, dark tint text.
@ViewBuilder
func dsBadge(_ text: String, tint: Color, soft: Color) -> some View {
    Text(text)
        .font(DS.Typo.caption)
        .lineLimit(1)
        .fixedSize()          // a badge never wraps mid-word
        .foregroundStyle(tint)
        .padding(.horizontal, DS.Space.xs)
        .padding(.vertical, 2)
        .background(Capsule().fill(soft))
}
