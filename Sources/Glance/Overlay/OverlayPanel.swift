import AppKit

/// Borderless, non-activating floating panel (FR3). Chosen over NSWindow so it
/// can take key focus for typing without fully activating the app, and float
/// above full-screen spaces (FR1).
final class OverlayPanel: NSPanel {

    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 620, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .popUpMenu // above normal windows and most full-screen content
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        // Not in Dock / App Switcher (FR3, FR5) — reinforced by .accessory policy.
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .utilityWindow
    }

    // Must become key so the text field receives input (FR3 fallback path).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // FR4: Esc dismisses. keyCode 53 = Escape.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?() // Esc via responder chain too
    }
}
