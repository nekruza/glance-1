import Carbon.HIToolbox
import Foundation

/// Registers a single global hotkey via Carbon `RegisterEventHotKey` (FR1).
///
/// Why Carbon and not CGEventTap: for a non-sandboxed, direct-distribution app
/// `RegisterEventHotKey` needs NO Accessibility permission and fires even over
/// full-screen apps — exactly FR1's requirement (addendum, Global hotkey note).
final class HotkeyManager {
    /// Called on the main thread each time the hotkey fires.
    var onFire: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var currentCombo: KeyCombo?

    private static let signature: OSType = {
        // FourCharCode 'GLnc'
        let chars = Array("GLnc".utf8)
        return (OSType(chars[0]) << 24) | (OSType(chars[1]) << 16) | (OSType(chars[2]) << 8) | OSType(chars[3])
    }()
    private static let hotKeyID: UInt32 = 1

    init() {
        installHandler()
    }

    deinit {
        unregister()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// (Re)bind to a combo. Safe to call repeatedly (FR17 rebinding).
    func register(_ combo: KeyCombo) {
        guard combo.isValid else { return }
        unregister()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(combo.keyCode,
                                         combo.modifiers,
                                         hotKeyID,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &ref)
        if status == noErr {
            hotKeyRef = ref
            currentCombo = combo
        } else {
            NSLog("Glance: RegisterEventHotKey failed (status \(status)) for \(combo.displayString)")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        currentCombo = nil
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(),
                            { _, event, userData in
                                guard let userData, let event else { return noErr }
                                var hkID = EventHotKeyID()
                                let err = GetEventParameter(event,
                                                            EventParamName(kEventParamDirectObject),
                                                            EventParamType(typeEventHotKeyID),
                                                            nil,
                                                            MemoryLayout<EventHotKeyID>.size,
                                                            nil,
                                                            &hkID)
                                guard err == noErr,
                                      hkID.signature == HotkeyManager.signature,
                                      hkID.id == HotkeyManager.hotKeyID else { return noErr }
                                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                                DispatchQueue.main.async { manager.onFire?() }
                                return noErr
                            },
                            1,
                            &spec,
                            selfPtr,
                            &eventHandler)
    }
}
