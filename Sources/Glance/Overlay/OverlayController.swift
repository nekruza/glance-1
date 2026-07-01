import AppKit
import SwiftUI

/// Owns the reusable overlay panel and its SwiftUI content. Reused across
/// invocations so presenting is a cheap show/center, not a window alloc (FR2).
@MainActor
final class OverlayController {

    private(set) var session = OverlaySession()
    private let panel = OverlayPanel()
    private var hostingView: NSHostingView<OverlayView>?
    private var clickOutsideMonitor: Any?

    /// Called when the overlay is dismissed for any reason (FR4).
    var onDismiss: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

    init() {
        panel.onCancel = { [weak self] in self?.dismiss() }
    }

    /// Present with a fresh session (FR12: each invocation is a clean slate).
    func present() {
        // Rebuild the session/content so no state leaks across invocations.
        session = OverlaySession()
        session.dismissHandler = { [weak self] in self?.dismiss() }

        let root = OverlayView(session: session)
        let host = NSHostingView(rootView: root)
        host.frame = panel.frame
        panel.contentView = host
        hostingView = host

        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(host)

        installClickOutsideMonitor()
    }

    /// Wire the submit action (set by the coordinator).
    func onSubmit(_ handler: @escaping (String) -> Void) {
        session.submitHandler = handler
    }

    func dismiss() {
        guard panel.isVisible else { return }
        removeClickOutsideMonitor()
        panel.orderOut(nil)
        onDismiss?()
    }

    // MARK: - Layout

    private func positionPanel() {
        // Center horizontally, upper third of the display under the cursor —
        // near where the user is looking, out of the way of content below.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.layoutIfNeeded()
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.midY + frame.height * 0.12
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Click-outside dismissal (FR4)

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            // Any click in another app dismisses.
            self?.dismiss()
        }
    }

    private func removeClickOutsideMonitor() {
        if let m = clickOutsideMonitor {
            NSEvent.removeMonitor(m)
            clickOutsideMonitor = nil
        }
    }
}
