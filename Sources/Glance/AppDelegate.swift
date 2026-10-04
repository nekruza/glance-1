import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController()
    private let coordinator = AppCoordinator()
    private let onboarding = OnboardingWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // FR5 / FR3: menu-bar app, no Dock, no App Switcher entry.
        NSApp.setActivationPolicy(.accessory)

        // Accessory apps have no main menu by default, which silently kills
        // ⌘C/⌘V/⌘X/⌘A/⌘Z in every text field — key equivalents route through
        // the menu. Install a minimal one (never visible, only routing).
        installMainMenu()

        statusItem.onAsk = { [weak coordinator] in coordinator?.summon() }
        statusItem.onTasks = { [weak coordinator] in coordinator?.summonTasks() }
        statusItem.onSettings = { [weak coordinator] in coordinator?.summonTaskSettings() }
        coordinator.onOpenSettings = { [weak statusItem] in statusItem?.showSettings() }
        statusItem.statusProvider = { [weak coordinator] in
            coordinator?.backendStatusLine() ?? (false, "AI provider status unknown")
        }
        statusItem.hotkeyWarningProvider = { [weak coordinator] in
            coordinator?.hotkeyWarnings() ?? []
        }
        statusItem.onWelcome = { [weak self] in self?.onboarding.present() }
        statusItem.install()
        coordinator.start()

        // First launch only: the welcome tour. Deferred a turn — ordering the
        // window in the same runloop turn as the accessory-policy setup loses
        // it when AppActivation flips the policy to .regular mid-launch.
        DispatchQueue.main.async { [weak self] in
            self?.onboarding.presentIfNeeded()
        }
    }

    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Glance",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All",
                     action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Start Dictation…",
                     action: Selector(("startDictation:")), keyEquivalent: "")
        editItem.submenu = edit

        NSApp.mainMenu = main
    }

    // Menu-bar app: closing a window (e.g. Settings) must not quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // The backend now outlives overlay dismissals; kill it on quit so no
    // orphaned claude process lingers.
    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }
}
