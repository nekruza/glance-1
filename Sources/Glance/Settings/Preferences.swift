import Foundation
import Combine

/// User settings (FR17 hotkey, FR18 launch-at-login). FR19: nothing else in v1.
/// Backed by UserDefaults; observable so Settings UI and HotkeyManager react.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Keys {
        static let hotkeyKeyCode = "hotkey.keyCode"
        static let hotkeyModifiers = "hotkey.modifiers"
        static let overlayOpacity = "overlay.opacity"
    }

    /// Default dark-tint opacity of the overlay background.
    static let defaultOverlayOpacity: Double = 0.7

    private let defaults = UserDefaults.standard

    @Published var hotkey: KeyCombo {
        didSet {
            defaults.set(Int(hotkey.keyCode), forKey: Keys.hotkeyKeyCode)
            defaults.set(Int(hotkey.modifiers), forKey: Keys.hotkeyModifiers)
        }
    }

    /// Overlay background opacity (0.2 barely-there … 1.0 solid).
    @Published var overlayOpacity: Double {
        didSet { defaults.set(overlayOpacity, forKey: Keys.overlayOpacity) }
    }

    private init() {
        if defaults.object(forKey: Keys.hotkeyKeyCode) != nil {
            let code = UInt32(defaults.integer(forKey: Keys.hotkeyKeyCode))
            let mods = UInt32(defaults.integer(forKey: Keys.hotkeyModifiers))
            let combo = KeyCombo(keyCode: code, modifiers: mods)
            hotkey = combo.isValid ? combo : .defaultCombo
        } else {
            hotkey = .defaultCombo
        }
        if defaults.object(forKey: Keys.overlayOpacity) != nil {
            overlayOpacity = min(max(defaults.double(forKey: Keys.overlayOpacity), 0.2), 1.0)
        } else {
            overlayOpacity = Self.defaultOverlayOpacity
        }
    }
}
