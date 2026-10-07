import AppKit

/// The overlay's window size: the designed default until the user drags an
/// edge, then whatever they chose — remembered across summons and launches.
/// Idle mode's height always follows its content (the prompt row grows with
/// the text), so only a conversation's height is user-sized.
struct OverlaySizing {
    static let defaultWidth: CGFloat = Theme.overlayWidth
    static let defaultConversationHeight: CGFloat = 560
    static let minWidth: CGFloat = 480
    static let minConversationHeight: CGFloat = 300

    private static let widthKey = "overlay.width"
    private static let heightKey = "overlay.conversationHeight"

    private let defaults: UserDefaults
    private(set) var width: CGFloat
    private(set) var conversationHeight: CGFloat

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let w = defaults.double(forKey: Self.widthKey)
        let h = defaults.double(forKey: Self.heightKey)
        width = w > 0 ? max(w, Self.minWidth) : Self.defaultWidth
        conversationHeight = h > 0 ? max(h, Self.minConversationHeight) : Self.defaultConversationHeight
    }

    func contentSize(isConversation: Bool, idleHeight: CGFloat) -> NSSize {
        NSSize(width: width, height: isConversation ? conversationHeight : idleHeight)
    }

    /// A finished edge drag (content size). Idle drags only carry the width.
    mutating func recordUserResize(_ size: NSSize, isConversation: Bool) {
        width = max(size.width, Self.minWidth)
        defaults.set(Double(width), forKey: Self.widthKey)
        guard isConversation else { return }
        conversationHeight = max(size.height, Self.minConversationHeight)
        defaults.set(Double(conversationHeight), forKey: Self.heightKey)
    }
}
