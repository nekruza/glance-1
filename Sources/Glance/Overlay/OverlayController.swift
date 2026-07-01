import AppKit
import SwiftUI
import Combine

/// Owns the reusable overlay panel and its SwiftUI content. Reused across
/// invocations so presenting is a cheap show/center, not a window alloc (FR2).
@MainActor
final class OverlayController {

    private(set) var session = OverlaySession()
    private let panel = OverlayPanel()
    private var hostingView: NSHostingView<OverlayView>?
    private var clickOutsideMonitor: Any?
    private var sizeCancellable: AnyCancellable?

    /// Deterministic window heights — no SwiftUI/window auto-sizing feedback
    /// loop (that raced and clipped the input + footer).
    private let conversationHeight: CGFloat = 560

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
        host.sizingOptions = [] // window size is set manually, never auto-tracked
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        hostingView = host

        // Compact idle size, measured from the idle content.
        let idleHeight = max(host.fittingSize.height, 96)
        panel.setContentSize(NSSize(width: 640, height: idleHeight))

        // Grow to the fixed conversation size on the first message; shrink back
        // if the transcript is ever emptied.
        sizeCancellable = session.$turns
            .map(\.isEmpty)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEmpty in
                guard let self else { return }
                let h = isEmpty ? idleHeight : self.conversationHeight
                self.panel.setContentSize(NSSize(width: 640, height: h))
            }

        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(host)

        installClickOutsideMonitor()
    }

    /// Wire the submit action (set by the coordinator).
    func onSubmit(_ handler: @escaping (String) -> Void) {
        session.submitHandler = handler
    }

    /// Make the panel invisible to screen capture without losing key focus or
    /// ending the session — used when capturing a fresh screenshot for a
    /// follow-up so the overlay itself stays out of the shot (FR8).
    func setHiddenForCapture(_ hidden: Bool) {
        panel.alphaValue = hidden ? 0 : 1
    }

    func dismiss() {
        guard panel.isVisible else { return }
        removeClickOutsideMonitor()
        panel.orderOut(nil)
        onDismiss?()
    }

    // MARK: - Layout

    private func positionPanel() {
        // Center horizontally, top edge in the upper third of the display under
        // the cursor. The panel auto-grows downward from this fixed top as the
        // answer streams (see OverlayPanel anchoring).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.layoutIfNeeded()
        let width = panel.frame.width
        panel.anchoredLeft = frame.midX - width / 2
        panel.anchoredTop = frame.minY + frame.height * 0.82
        panel.reanchor()
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
