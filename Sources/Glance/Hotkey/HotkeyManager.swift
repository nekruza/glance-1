import Carbon.HIToolbox
import Foundation

/// Registers global hotkeys via Carbon `RegisterEventHotKey` (FR1, FR20).
///
/// Why Carbon and not CGEventTap: for a non-sandboxed, direct-distribution app
/// `RegisterEventHotKey` needs NO Accessibility permission and fires even over
/// full-screen apps — exactly FR1's requirement (addendum, Global hotkey note).
///
/// V2: multiple slots — one per overlay (ask, tasks). Each slot has a stable
/// Carbon id and its own callback; rebinding a slot is idempotent.
final class HotkeyManager {

    enum Slot: UInt32, CaseIterable {
        case ask = 1
        case tasks = 2
    }

    private var hotKeyRefs: [Slot: EventHotKeyRef] = [:]
    private var callbacks: [Slot: () -> Void] = [:]
    private var combos: [Slot: KeyCombo] = [:]
    private var eventHandler: EventHandlerRef?

    /// Slots whose last `RegisterEventHotKey` call failed (e.g. another app
    /// holds the combo exclusively). Registration is otherwise one-shot, so
    /// failures are sticky until a retry or a rebind succeeds.
    private(set) var failures: [Slot: OSStatus] = [:] {
        didSet { syncRetryTimer() }
    }

    /// Alive only while `failures` is non-empty — no idle polling when healthy.
    private var retryTimer: Timer?

    /// Human-readable descriptions of failed bindings, for the menu warning.
    var failureDescriptions: [String] {
        failures.compactMap { slot, _ in
            combos[slot].map { "\($0.displayString) is taken by another app" }
        }
    }

    private static let signature: OSType = {
        // FourCharCode 'GLnc'
        let chars = Array("GLnc".utf8)
        return (OSType(chars[0]) << 24) | (OSType(chars[1]) << 16) | (OSType(chars[2]) << 8) | OSType(chars[3])
    }()

    /// Back-compat single-hotkey API (V1 call sites): the ask slot.
    var onFire: (() -> Void)? {
        get { callbacks[.ask] }
        set { callbacks[.ask] = newValue }
    }

    init() {
        installHandler()
    }

    deinit {
        retryTimer?.invalidate()
        for slot in Slot.allCases { unregister(slot) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// V1 API — binds the ask slot (FR17 rebinding).
    func register(_ combo: KeyCombo) {
        register(combo, for: .ask)
    }

    /// (Re)bind a slot to a combo. Safe to call repeatedly.
    func register(_ combo: KeyCombo, for slot: Slot, onFire: (() -> Void)? = nil) {
        guard combo.isValid else { return }
        if let onFire { callbacks[slot] = onFire }
        combos[slot] = combo
        unregister(slot)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: slot.rawValue)
        let status = RegisterEventHotKey(combo.keyCode,
                                         combo.modifiers,
                                         hotKeyID,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &ref)
        if status == noErr {
            hotKeyRefs[slot] = ref
            failures[slot] = nil
        } else {
            failures[slot] = status
            NSLog("Glance: RegisterEventHotKey failed (status \(status)) for \(combo.displayString)")
        }
    }

    /// Retry slots whose registration failed. A grab lost at launch (combo
    /// held by another app that has since quit) is recaptured here — Carbon
    /// never retries on its own. Healthy slots are left untouched so an
    /// active binding is never cycled. No-op when everything is bound.
    func retryFailedRegistrations() {
        for slot in Array(failures.keys) {
            if let combo = combos[slot] { register(combo, for: slot) }
        }
    }

    /// Start the retry timer on the first failure; stop it once all slots
    /// bind again. `.common` mode so it fires even during menu tracking.
    private func syncRetryTimer() {
        if failures.isEmpty {
            retryTimer?.invalidate()
            retryTimer = nil
        } else if retryTimer == nil {
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                self?.retryFailedRegistrations()
            }
            RunLoop.main.add(timer, forMode: .common)
            retryTimer = timer
        }
    }

    func unregister(_ slot: Slot = .ask) {
        if let ref = hotKeyRefs.removeValue(forKey: slot) {
            UnregisterEventHotKey(ref)
        }
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
                                      let slot = HotkeyManager.Slot(rawValue: hkID.id) else { return noErr }
                                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                                DispatchQueue.main.async { manager.callbacks[slot]?() }
                                return noErr
                            },
                            1,
                            &spec,
                            selfPtr,
                            &eventHandler)
    }
}
