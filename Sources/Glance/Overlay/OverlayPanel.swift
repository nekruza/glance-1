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
        hasShadow = false
        hidesOnDeactivate = false
        // Drag anywhere that isn't a control (header, paddings, footer).
        isMovableByWindowBackground = true
        // Force dark so the glass reads dark regardless of the desktop behind it
        // (design contract: dark-glass overlay).
        appearance = NSAppearance(named: .darkAqua)
        // Not in Dock / App Switcher (FR3, FR5) — reinforced by .accessory policy.
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .utilityWindow

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidMove(_:)),
            name: NSWindow.didMoveNotification, object: self)
    }

    // Must become key so the text field receives input (FR3 fallback path).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Screen coords to keep fixed as the panel auto-resizes to its SwiftUI
    /// content (streaming answers grow the panel). Left edge stays put; top edge
    /// stays put so the panel expands downward.
    var anchoredLeft: CGFloat?
    var anchoredTop: CGFloat?
    /// Set once the user drags the panel; the controller then stops recentering
    /// it on each summon.
    private(set) var userMoved = false
    private var isProgrammaticMove = false

    override func setContentSize(_ size: NSSize) {
        super.setContentSize(size)
        reanchor()
    }

    func reanchor() {
        guard let left = anchoredLeft, let top = anchoredTop else { return }
        isProgrammaticMove = true
        setFrameOrigin(NSPoint(x: left, y: top - frame.height))
        isProgrammaticMove = false
    }

    /// A drag moved the window: adopt the new spot as the anchor so the next
    /// resize/reanchor doesn't snap it back.
    @objc private func windowDidMove(_ note: Notification) {
        guard !isProgrammaticMove else { return }
        userMoved = true
        anchoredLeft = frame.minX
        anchoredTop = frame.maxY
    }

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
