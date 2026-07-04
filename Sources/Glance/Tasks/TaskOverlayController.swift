import AppKit
import SwiftUI

/// Owns the task-board overlay panel (FR20). Mirrors OverlayController's
/// panel handling: reusable panel, drag-respected positioning, explicit close.
@MainActor
final class TaskOverlayController {

    let session: TaskBoardSession
    private let store: TaskStore
    private let panel = OverlayPanel()
    private var hostingView: NSHostingView<TaskBoardView>?

    var isVisible: Bool { panel.isVisible }
    var onOpenSettings: (() -> Void)?

    init(store: TaskStore, runner: TaskRunner, ai: TaskAI, ingest: ComposioIngest) {
        self.store = store
        session = TaskBoardSession(store: store, runner: runner, ai: ai, ingest: ingest)
        session.dismissHandler = { [weak self] in self?.dismiss() }
        session.settingsHandler = { [weak self] in
            self?.dismiss()
            self?.onOpenSettings?()
        }
        panel.onCancel = { [weak self] in self?.dismiss() }
    }

    func toggle() {
        if panel.isVisible { dismiss() } else { present() }
    }

    func present() {
        if hostingView == nil {
            let host = NSHostingView(rootView: TaskBoardView(session: session, store: store))
            host.sizingOptions = []
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            hostingView = host
        }
        panel.setContentSize(NSSize(width: 700, height: 640))
        position()
        panel.makeKeyAndOrderFront(nil)
        if let host = hostingView { panel.makeFirstResponder(host) }
        // Re-prioritize opportunistically on summon (batched inside).
        session.schedulePrioritize()
    }

    func dismiss() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// Focus the board on a specific task (notification click-through, FR56).
    func reveal(taskId: UUID) {
        session.selectedTaskId = taskId
        present()
    }

    private func position() {
        if panel.userMoved {
            panel.reanchor()
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.layoutIfNeeded()
        panel.anchoredLeft = frame.midX - panel.frame.width / 2
        panel.anchoredTop = frame.minY + frame.height * 0.9
        panel.reanchor()
    }
}
