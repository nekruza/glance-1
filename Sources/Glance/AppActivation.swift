import AppKit

/// Flips the app between menu-bar-only (.accessory) and full-app (.regular)
/// presence. Each "app window" (Tasks board, legacy Settings) acquires a
/// token while visible; when the last one releases, the dock icon goes away.
@MainActor
enum AppActivation {
    private static var holders = Set<String>()

    static func acquire(_ token: String) {
        holders.insert(token)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func release(_ token: String) {
        holders.remove(token)
        if holders.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
