import AppKit
import SwiftUI

/// FR5: menu-bar presence with a minimal menu (Settings, Quit). No Dock.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkle.magnifyingglass",
                                   accessibilityDescription: "Glance")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        let hotkeyLabel = NSMenuItem(title: "Summon: \(Preferences.shared.hotkey.displayString)",
                                     action: nil, keyEquivalent: "")
        hotkeyLabel.isEnabled = false
        menu.addItem(hotkeyLabel)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…",
                                action: #selector(openSettings),
                                keyEquivalent: ",").withTarget(self))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Glance",
                                action: #selector(quit),
                                keyEquivalent: "q").withTarget(self))
        item.menu = menu
        statusItem = item
    }

    @objc private func openSettings() {
        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Glance Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        settingsWindow = nil
    }
}

private extension NSMenuItem {
    func withTarget(_ target: AnyObject) -> NSMenuItem {
        self.target = target
        return self
    }
}
