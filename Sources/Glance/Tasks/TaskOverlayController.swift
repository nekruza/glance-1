import AppKit
import SwiftUI

/// Owns the task-board app window (full window, Slack-like — not an overlay).
/// Reusable window, frame autosaved, dock/Cmd-Tab presence while open via
/// AppActivation.
@MainActor
final class TaskOverlayController: NSObject, NSWindowDelegate {

    let session: TaskBoardSession
    private let store: TaskStore
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }
    var onOpenSettings: (() -> Void)?

    init(store: TaskStore, runner: TaskRunner, ai: TaskAI, ingest: ComposioIngest) {
        self.store = store
        session = TaskBoardSession(store: store, runner: runner, ai: ai, ingest: ingest)
        super.init()
        session.dismissHandler = { [weak self] in self?.dismiss() }
        session.settingsHandler = { [weak self] in
            self?.dismiss()
            self?.onOpenSettings?()
        }
    }

    func toggle() {
        if let window, window.isVisible, window.isKeyWindow {
            dismiss()
        } else {
            present()
        }
    }

    func present() {
        let window = ensureWindow()
        if window.isMiniaturized { window.deminiaturize(nil) }
        AppActivation.acquire("tasks")
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
        AppActivation.release("tasks")
    }

    /// Focus the board on a specific task (notification click-through, FR56).
    func reveal(taskId: UUID) {
        session.selectedTaskId = taskId
        present()
    }

    // MARK: - Window

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let host = NSHostingController(rootView: TaskBoardView(session: session, store: store))
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.title = "Glance Tasks"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.contentMinSize = NSSize(width: 900, height: 560)
        w.appearance = NSAppearance(named: .aqua)
        w.backgroundColor = .white
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 1000, height: 700))
        w.center()
        w.setFrameAutosaveName("GlanceTasksWindow")
        window = w
        return w
    }

    // Traffic-light close: window hides (isReleasedWhenClosed = false); drop
    // the app's dock presence with it.
    func windowWillClose(_ notification: Notification) {
        AppActivation.release("tasks")
    }
}
