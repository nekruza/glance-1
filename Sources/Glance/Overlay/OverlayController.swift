import AppKit
import SwiftUI
import Combine

/// Owns the reusable overlay panel and its SwiftUI content. Reused across
/// invocations so presenting is a cheap show/center, not a window alloc (FR2)
/// — replaced only when a display change may have broken it (see
/// `panelIsStale`).
@MainActor
final class OverlayController {

    private(set) var session = OverlaySession()
    private var panel = OverlayPanel()
    /// A display hot-plug can leave the long-lived panel in no Space at all:
    /// AppKit still orders it in, but the window server draws it nowhere, so
    /// ⌥Space "does nothing" until relaunch (seen live: panel in zero Spaces
    /// after a monitor swap). Set on any display change; the panel is swapped
    /// for a fresh one before it is next shown.
    private var panelIsStale = false
    private var screenObserver: NSObjectProtocol?
    private var hostingView: NSHostingView<OverlayView>?
    private var sizeCancellable: AnyCancellable?
    private var heightCancellable: AnyCancellable?
    private var keyMonitor: Any?

    /// Deterministic window sizes — no SwiftUI/window auto-sizing feedback
    /// loop (that raced and clipped the input + footer). Width and the
    /// conversation height follow the user's last edge drag.
    private var sizing = OverlaySizing()
    private var resizeObserver: NSObjectProtocol?
    /// Measured from the idle content the first time we present while empty.
    private var idleHeight: CGFloat = 96

    /// Called when the overlay is dismissed for any reason (FR4).
    var onDismiss: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

    init() {
        panel.onCancel = { [weak self] in self?.cancel() }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? NSWindow) === self.panel else { return }
                self.userDidResize()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        }
    }

    /// Present the reusable overlay for a fresh invocation.
    func present() {
        if panelIsStale { replacePanel() }
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
        applySize()

        // Grow to the fixed conversation size on the first message; shrink back
        // if the transcript is ever emptied.
        sizeCancellable = session.$turns
            .map(\.isEmpty)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applySize() }

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
                self.applySize()
            }

        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(host)
        installKeyMonitor()
        replacePanelIfNotDrawn()
    }

    // MARK: - Panel recovery

    /// Hidden: swap lazily on the next present(), once the display setup has
    /// settled (a hot-plug fires several of these). Visible: swap after a short
    /// settle so the open conversation reappears without another ⌥Space.
    private func screenParametersChanged() {
        panelIsStale = true
        guard panel.isVisible else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.panelIsStale, self.panel.isVisible else { return }
            self.replacePanel()
        }
    }

    /// Backstop for breakage no notification announced: once the order-in has
    /// landed, ask the window server whether the panel is really on screen.
    private func replacePanelIfNotDrawn() {
        let shown = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.panel === shown, shown.isVisible,
                  !Self.windowServerShows(shown) else { return }
            NSLog("Glance: overlay panel ordered in but not on screen — replacing it")
            self.replacePanel()
        }
    }

    private static func windowServerShows(_ window: NSWindow) -> Bool {
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow,
                                              CGWindowID(window.windowNumber)) as? [[String: Any]]
        guard let entry = info?.first else { return true } // unknown: don't churn
        return entry[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    /// Retire the current panel for a fresh one, moving the live content
    /// across if it was showing. The session (conversation) lives outside the
    /// panel, so nothing the user typed or read is lost.
    private func replacePanel() {
        panelIsStale = false
        let old = panel
        let wasVisible = old.isVisible
        panel = OverlayPanel()
        panel.onCancel = { [weak self] in self?.cancel() }
        old.onCancel = nil
        old.contentView = nil
        // close() frees the window-server window (orderOut alone leaks one per
        // display change); ARC owns the object, so AppKit must not release it.
        old.isReleasedWhenClosed = false
        old.close()
        guard wasVisible, let host = hostingView else { return }
        panel.contentView = host
        applySize()
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(host)
    }

    /// ⌘J toggles the screenshot attachment while the overlay is up. A local
    /// monitor rather than performKeyEquivalent/.keyboardShortcut: the panel is
    /// non-activating, so AppKit skips key-equivalent dispatch while the app is
    /// inactive — which is the normal case for the overlay. Scoped to events
    /// aimed at the panel so Settings and the task board are unaffected, and it
    /// swallows the event so the focused field editor doesn't beep at it.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, event.window === self.panel,
                  OverlayPanel.isAttachShortcut(characters: event.charactersIgnoringModifiers,
                                                modifiers: event.modifierFlags)
            else { return event }
            self.session.toggleAttachImage()
            return nil
        }
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

    /// Esc: close the `/` menu if it's open, otherwise the overlay. (The
    /// view's key handler normally takes Esc first; this covers the field
    /// editor routing it through cancelOperation instead.)
    private func cancel() {
        if session.dismissSlashMenu() { return }
        dismiss()
    }

    func dismiss() {
        guard panel.isVisible else { return }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        panel.orderOut(nil)
        onDismiss?()
    }

    // MARK: - Layout

    /// One source of truth for the window size: height is idle-compact until
    /// there's a conversation to show.
    private func applySize() {
        let conversation = !session.turns.isEmpty
        var size = sizing.contentSize(isConversation: conversation, idleHeight: idleHeight)
        // Mid-drag the idle height re-measures as text rewraps; keep the
        // width under the user's pointer rather than the last saved one.
        if panel.inLiveResize, let content = panel.contentView {
            size.width = content.frame.width
        }
        // Idle height follows the content, so only the width is draggable there.
        panel.contentMinSize = NSSize(width: OverlaySizing.minWidth,
                                      height: conversation ? OverlaySizing.minConversationHeight : size.height)
        panel.contentMaxSize = NSSize(width: 10_000, height: conversation ? 10_000 : size.height)
        panel.setContentSize(size)
    }

    /// An edge drag ended: remember the size, and pin the panel's new top-left
    /// so the next auto-resize grows from where the user left it.
    private func userDidResize() {
        let content = panel.contentRect(forFrameRect: panel.frame).size
        sizing.recordUserResize(content, isConversation: !session.turns.isEmpty)
        panel.anchoredLeft = panel.frame.minX
        panel.anchoredTop = panel.frame.maxY
    }

    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        // Once the user has dragged the panel somewhere, respect that spot on
        // every summon — but only while it's on the display being summoned on.
        // A dragged anchor is an absolute point that encodes a display; without
        // this check ⌥Space keeps reopening on whichever screen the drag
        // happened, not the one the user is working on.
        if panel.userMoved, let left = panel.anchoredLeft, let top = panel.anchoredTop,
           screen.map({ NSMouseInRect(NSPoint(x: left, y: top - 1), $0.frame, false) }) == true {
            panel.reanchor()
            return
        }
        // Center horizontally, top edge in the upper third of the display under
        // the cursor. The panel auto-grows downward from this fixed top as the
        // answer streams (see OverlayPanel anchoring).
        guard let frame = screen?.visibleFrame else { return }
        panel.layoutIfNeeded()
        let width = panel.frame.width
        panel.anchoredLeft = frame.midX - width / 2
        panel.anchoredTop = frame.minY + frame.height * 0.82
        panel.reanchor()
    }

}
