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
    private var sizeCancellable: AnyCancellable?
    private var heightCancellable: AnyCancellable?

    /// Deterministic window heights — no SwiftUI/window auto-sizing feedback
    /// loop (that raced and clipped the input + footer).
    private let conversationHeight: CGFloat = 560
    /// Measured from the idle content the first time we present while empty.
    private var idleHeight: CGFloat = 96

    /// Called when the overlay is dismissed for any reason (FR4).
    var onDismiss: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

    init() {
        panel.onCancel = { [weak self] in self?.dismiss() }
    }

    /// Present the overlay. The session persists across dismissals — previous
    /// messages stay until the user clears them with the trash button.
    func present() {
        session.dismissHandler = { [weak self] in self?.dismiss() }

        let root = OverlayView(session: session)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = [] // window size is set manually, never auto-tracked
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        hostingView = host

        // Compact idle size, measured from the idle content. Only measurable
        // while the transcript is empty — a conversation would measure the
        // (unbounded) transcript instead.
        panel.setContentSize(NSSize(width: 640,
                                    height: session.turns.isEmpty ? idleHeight : conversationHeight))

        // Grow to the fixed conversation size on the first message; shrink back
        // if the transcript is ever emptied.
        sizeCancellable = session.$turns
            .map(\.isEmpty)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEmpty in
                guard let self else { return }
                let h = isEmpty ? self.idleHeight : self.conversationHeight
                self.panel.setContentSize(NSSize(width: 640, height: h))
            }

        // Idle window height tracks the TRUE rendered content height reported
        // by the view (GeometryReader) — measuring the hosting view from AppKit
        // under-reported and clipped the rounded corners top and bottom. Idle
        // content height doesn't depend on the window height, so this settles
        // in one step (no resize feedback loop).
        heightCancellable = session.$contentHeight
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] h in
                guard let self, self.session.turns.isEmpty, h > 20 else { return }
                self.idleHeight = ceil(h)
                self.panel.setContentSize(NSSize(width: 640, height: self.idleHeight))
            }

        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(host)
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
        panel.orderOut(nil)
        onDismiss?()
    }

    // MARK: - Layout

    private func positionPanel() {
        // Once the user has dragged the panel somewhere, respect that spot on
        // every summon; only re-apply the anchors for the current size.
        if panel.userMoved {
            panel.reanchor()
            return
        }
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

}
