import Carbon.HIToolbox
import Foundation

/// A global hotkey: a virtual key code plus Carbon modifier flags.
/// Persisted as two ints in UserDefaults. Default = ⌥Space (FR1 / OQ1).
struct KeyCombo: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier mask (optionKey, cmdKey, ...)

    /// FR1 default. ⌥Space. OQ1 flags a possible Raycast/Alfred collision;
    /// FR17 rebind makes it non-fatal.
    static let defaultCombo = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))

    /// V2 FR20 default for the task board. ⌥T.
    static let defaultTaskCombo = KeyCombo(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey))

    /// Human-readable label for the menu / settings ("⌥Space").
    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += KeyCombo.keyName(for: keyCode)
        return s
    }

    /// Whether the combo is usable as a global hotkey. We require at least one
    /// modifier so a bare letter can't hijack global typing.
    var isValid: Bool { modifiers != 0 }

    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Escape: return "⎋"
        case kVK_Tab: return "⇥"
        default:
            // Best-effort character from the current keyboard layout.
            if let ch = Self.character(for: keyCode) { return ch.uppercased() }
            return "key\(keyCode)"
        }
    }

    /// Translate a virtual key code to its unmodified character via the active
    /// keyboard layout (so labels are correct on non-US layouts).
    private static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let result = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout,
                                  UInt16(keyCode),
                                  UInt16(kUCKeyActionDisplay),
                                  0,
                                  UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys,
                                  chars.count,
                                  &length,
                                  &chars)
        }
        guard result == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
