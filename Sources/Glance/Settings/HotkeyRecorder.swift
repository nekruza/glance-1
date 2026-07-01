import AppKit
import SwiftUI
import Carbon.HIToolbox

/// FR17: a click-to-record control that captures the next modifier+key combo.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var combo: KeyCombo

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton()
        b.combo = combo
        b.onChange = { self.combo = $0 }
        return b
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.combo = combo
        nsView.refreshTitle()
    }

    final class RecorderButton: NSButton {
        var combo: KeyCombo = .defaultCombo
        var onChange: ((KeyCombo) -> Void)?
        private var recording = false
        private var monitor: Any?

        override init(frame: NSRect) {
            super.init(frame: frame)
            bezelStyle = .rounded
            setButtonType(.momentaryPushIn)
            target = self
            action = #selector(toggleRecording)
            refreshTitle()
        }

        required init?(coder: NSCoder) { fatalError() }

        func refreshTitle() {
            title = recording ? "Press keys…" : combo.displayString
        }

        @objc private func toggleRecording() {
            recording.toggle()
            refreshTitle()
            if recording { startMonitor() } else { stopMonitor() }
        }

        private func startMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self else { return event }
                let mods = Self.carbonModifiers(from: event.modifierFlags)
                let candidate = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods)
                if event.keyCode == 53 { // Esc cancels recording
                    self.recording = false; self.stopMonitor(); self.refreshTitle(); return nil
                }
                guard candidate.isValid else { return nil } // require a modifier
                self.combo = candidate
                self.onChange?(candidate)
                self.recording = false
                self.stopMonitor()
                self.refreshTitle()
                return nil
            }
        }

        private func stopMonitor() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }

        private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
            var m: UInt32 = 0
            if flags.contains(.command) { m |= UInt32(cmdKey) }
            if flags.contains(.option)  { m |= UInt32(optionKey) }
            if flags.contains(.control) { m |= UInt32(controlKey) }
            if flags.contains(.shift)   { m |= UInt32(shiftKey) }
            return m
        }
    }
}
