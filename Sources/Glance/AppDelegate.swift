import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController()
    private let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // FR5 / FR3: menu-bar app, no Dock, no App Switcher entry.
        NSApp.setActivationPolicy(.accessory)

        statusItem.onAsk = { [weak coordinator] in coordinator?.summon() }
        statusItem.statusProvider = { [weak coordinator] in
            coordinator?.backendStatusLine() ?? (false, "Claude CLI status unknown")
        }
        statusItem.install()
        coordinator.start()
    }

    // Menu-bar app: closing a window (e.g. Settings) must not quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
