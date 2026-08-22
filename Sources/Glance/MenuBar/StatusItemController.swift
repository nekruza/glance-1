import AppKit
import SwiftUI

/// FR5: menu-bar presence, styled to 03-menubar-dropdown (app header, AI provider
/// status line, Ask / Settings / Quit). No Dock.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate, NSMenuDelegate {

    /// Set by the app delegate; summons the overlay.
    var onAsk: (() -> Void)?
    /// Summons the V2 task board.
    var onTasks: (() -> Void)?
    var onSettings: (() -> Void)?
    /// Provides the live backend status for the status line.
    var statusProvider: (() -> (connected: Bool, label: String))?
    /// Provides hotkey bindings that failed to register (empty = all good).
    var hotkeyWarningProvider: (() -> [String])?
    /// Re-opens the first-launch welcome tour.
    var onWelcome: (() -> Void)?

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var statusLineItem: NSMenuItem?
    private var hotkeyWarningItem: NSMenuItem?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // Stays the `sparkle` symbol, not the app logo (`BrandMark`): a
            // status item is a template image, so macOS would flatten the
            // logo's gradient squircle into one solid silhouette. The symbol
            // also tracks the menu bar's light/dark appearance for free.
            // The onboarding copy and MenuBarMock illustration both depict
            // this icon — change all three together or none.
            button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Glance")
            button.image?.isTemplate = true
        }
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        // Header: app identity.
        let header = NSMenuItem()
        header.isEnabled = false
        header.attributedTitle = attributed([
            ("Glance", NSColor.labelColor, NSFont.systemFont(ofSize: 13, weight: .semibold)),
            ("  v1.0", NSColor.secondaryLabelColor, NSFont.systemFont(ofSize: 11))
        ])
        menu.addItem(header)

        // Backend status line (refreshed on open).
        let status = NSMenuItem()
        status.isEnabled = false
        statusLineItem = status
        menu.addItem(status)

        // Hotkey conflict warning (hidden unless a binding failed).
        let hotkeyWarning = NSMenuItem()
        hotkeyWarning.isEnabled = false
        hotkeyWarning.isHidden = true
        hotkeyWarningItem = hotkeyWarning
        menu.addItem(hotkeyWarning)

        menu.addItem(.separator())

        let ask = NSMenuItem(title: "Ask about screen…", action: #selector(askAction), keyEquivalent: "")
        ask.target = self
        menu.addItem(ask)

        let tasks = NSMenuItem(title: "Tasks…", action: #selector(tasksAction), keyEquivalent: "")
        tasks.target = self
        menu.addItem(tasks)

        menu.addItem(.separator())

        let welcome = NSMenuItem(title: "Welcome Tour…", action: #selector(welcomeAction), keyEquivalent: "")
        welcome.target = self
        menu.addItem(welcome)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Glance", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        refreshStatusLine()
        return menu
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        refreshStatusLine()
    }

    private func refreshStatusLine() {
        let (connected, label) = statusProvider?() ?? (false, "AI provider status unknown")
        let dot = connected ? "● " : "○ "
        let color = connected ? NSColor.systemGreen : NSColor.systemOrange
        statusLineItem?.attributedTitle = attributed([
            (dot, color, NSFont.systemFont(ofSize: 12)),
            (label, NSColor.secondaryLabelColor, NSFont.systemFont(ofSize: 12))
        ])

        let warnings = hotkeyWarningProvider?() ?? []
        hotkeyWarningItem?.isHidden = warnings.isEmpty
        if !warnings.isEmpty {
            hotkeyWarningItem?.attributedTitle = attributed([
                ("⚠ ", NSColor.systemOrange, NSFont.systemFont(ofSize: 12)),
                (warnings.joined(separator: " · "), NSColor.secondaryLabelColor,
                 NSFont.systemFont(ofSize: 12))
            ])
        }
    }

    // MARK: - Actions

    @objc private func askAction() { onAsk?() }

    @objc private func tasksAction() { onTasks?() }

    @objc private func welcomeAction() { onWelcome?() }

    /// Legacy small Settings window — fallback used only when the task
    /// system (and its in-window settings page) is unavailable.
    func showSettings() { openLegacySettings() }

    @objc private func openSettings() {
        if let onSettings { onSettings() } else { openLegacySettings() }
    }

    private func openLegacySettings() {
        if let window = settingsWindow {
            AppActivation.acquire("settings-legacy")
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
        AppActivation.acquire("settings-legacy")
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func windowWillClose(_ notification: Notification) {
        settingsWindow = nil
        AppActivation.release("settings-legacy")
    }

    // MARK: - Helpers

    private func attributed(_ parts: [(String, NSColor, NSFont)]) -> NSAttributedString {
        let s = NSMutableAttributedString()
        for (text, color, font) in parts {
            s.append(NSAttributedString(string: text, attributes: [.foregroundColor: color, .font: font]))
        }
        return s
    }
}
