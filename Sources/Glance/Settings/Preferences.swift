import Foundation
import Combine
import SwiftUI

/// User settings (FR17 hotkey, FR18 launch-at-login). FR19: nothing else in v1.
/// Backed by UserDefaults; observable so Settings UI and HotkeyManager react.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Keys {
        static let hotkeyKeyCode = "hotkey.keyCode"
        static let hotkeyModifiers = "hotkey.modifiers"
        static let overlayOpacity = "overlay.opacity"
        static let accentHex = "overlay.accentHex"
        static let taskHotkeyKeyCode = "taskHotkey.keyCode"
        static let taskHotkeyModifiers = "taskHotkey.modifiers"
        static let repos = "tasks.repos"
        static let autoPlanApprove = "tasks.autoPlanApprove"
        static let composioURL = "composio.url"
        static let composioKey = "composio.key"
    }

    /// Default dark-tint opacity of the overlay background.
    static let defaultOverlayOpacity: Double = 0.7

    /// Default accent — Uber Eats green.
    static let defaultAccentHex = "06C167"

    private let defaults = UserDefaults.standard

    @Published var hotkey: KeyCombo {
        didSet {
            defaults.set(Int(hotkey.keyCode), forKey: Keys.hotkeyKeyCode)
            defaults.set(Int(hotkey.modifiers), forKey: Keys.hotkeyModifiers)
        }
    }

    /// Task-board hotkey (V2 FR20). Default ⌥T.
    @Published var taskHotkey: KeyCombo {
        didSet {
            defaults.set(Int(taskHotkey.keyCode), forKey: Keys.taskHotkeyKeyCode)
            defaults.set(Int(taskHotkey.modifiers), forKey: Keys.taskHotkeyModifiers)
        }
    }

    /// Repo registry (V2 FR60) — used by enrichment mapping + workspace picker.
    @Published var repos: [RepoEntry] {
        didSet {
            if let data = try? JSONEncoder().encode(repos) {
                defaults.set(data, forKey: Keys.repos)
            }
        }
    }

    /// §6 A7: auto-approve plans for small non-code tasks with no boundary
    /// actions. Code tasks are always gated regardless.
    @Published var autoPlanApprove: Bool {
        didSet { defaults.set(autoPlanApprove, forKey: Keys.autoPlanApprove) }
    }

    /// Composio MCP endpoint + API key (read-only ingestion for Jira/Slack/
    /// Granola). Stored in defaults — single-user personal tool; NFR11's
    /// "no external credentials" posture is knowingly relaxed here.
    @Published var composioURL: String {
        didSet { defaults.set(composioURL, forKey: Keys.composioURL) }
    }
    @Published var composioKey: String {
        didSet { defaults.set(composioKey, forKey: Keys.composioKey) }
    }

    /// Overlay background opacity (0.2 barely-there … 1.0 solid).
    @Published var overlayOpacity: Double {
        didSet { defaults.set(overlayOpacity, forKey: Keys.overlayOpacity) }
    }

    /// Accent color as an RRGGBB hex string (drives Theme.accent everywhere).
    @Published var accentHex: String {
        didSet { defaults.set(accentHex, forKey: Keys.accentHex) }
    }

    var accentColor: Color {
        get { Color(hexRGB: accentHex) ?? Color(hexRGB: Self.defaultAccentHex)! }
        set { accentHex = newValue.hexRGB ?? Self.defaultAccentHex }
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
        accentHex = defaults.string(forKey: Keys.accentHex) ?? Self.defaultAccentHex
        if defaults.object(forKey: Keys.taskHotkeyKeyCode) != nil {
            let code = UInt32(defaults.integer(forKey: Keys.taskHotkeyKeyCode))
            let mods = UInt32(defaults.integer(forKey: Keys.taskHotkeyModifiers))
            let combo = KeyCombo(keyCode: code, modifiers: mods)
            taskHotkey = combo.isValid ? combo : .defaultTaskCombo
        } else {
            taskHotkey = .defaultTaskCombo
        }
        if let data = defaults.data(forKey: Keys.repos),
           let decoded = try? JSONDecoder().decode([RepoEntry].self, from: data) {
            repos = decoded
        } else {
            repos = []
        }
        autoPlanApprove = defaults.object(forKey: Keys.autoPlanApprove) == nil
            ? true : defaults.bool(forKey: Keys.autoPlanApprove)
        composioURL = defaults.string(forKey: Keys.composioURL) ?? "https://connect.composio.dev/mcp"
        composioKey = defaults.string(forKey: Keys.composioKey) ?? ""
    }
}

// MARK: - Hex color helpers

extension Color {
    /// "RRGGBB" (with or without leading #) → Color, sRGB.
    init?(hexRGB: String) {
        var s = hexRGB.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255,
                  green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255)
    }

    /// Color → "RRGGBB" (sRGB, alpha dropped).
    var hexRGB: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}
