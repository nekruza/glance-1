import Foundation
import Combine

/// User settings (FR17 hotkey, FR18 launch-at-login). FR19: nothing else in v1.
/// Backed by UserDefaults; observable so Settings UI and HotkeyManager react.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Keys {
        static let hotkeyKeyCode = "hotkey.keyCode"
        static let hotkeyModifiers = "hotkey.modifiers"
    }

    private let defaults = UserDefaults.standard

    @Published var hotkey: KeyCombo {
        didSet {
            defaults.set(Int(hotkey.keyCode), forKey: Keys.hotkeyKeyCode)
            defaults.set(Int(hotkey.modifiers), forKey: Keys.hotkeyModifiers)
        }
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
    }
}
