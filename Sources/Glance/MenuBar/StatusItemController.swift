import AppKit
import SwiftUI

/// FR5: menu-bar presence, styled to 03-menubar-dropdown (app header, Claude CLI
/// status line, Ask / Settings / Quit). No Dock.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate, NSMenuDelegate {

    /// Set by the app delegate; summons the overlay.
    var onAsk: (() -> Void)?
    /// Provides the live backend status for the status line.
    var statusProvider: (() -> (connected: Bool, label: String))?

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var statusLineItem: NSMenuItem?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
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

        menu.addItem(.separator())

        let ask = NSMenuItem(title: "Ask about screen…", action: #selector(askAction), keyEquivalent: "")
        ask.target = self
        menu.addItem(ask)

        menu.addItem(.separator())

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

    func menuWillOpen(_ menu: NSMenu) { refreshStatusLine() }

    private func refreshStatusLine() {
        let (connected, label) = statusProvider?() ?? (false, "Claude CLI status unknown")
        let dot = connected ? "● " : "○ "
        let color = connected ? NSColor.systemGreen : NSColor.systemOrange
        statusLineItem?.attributedTitle = attributed([
            (dot, color, NSFont.systemFont(ofSize: 12)),
            (label, NSColor.secondaryLabelColor, NSFont.systemFont(ofSize: 12))
        ])
    }

    // MARK: - Actions

    @objc private func askAction() { onAsk?() }

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

    @objc private func quit() { NSApp.terminate(nil) }

    func windowWillClose(_ notification: Notification) { settingsWindow = nil }

    // MARK: - Helpers

    private func attributed(_ parts: [(String, NSColor, NSFont)]) -> NSAttributedString {
        let s = NSMutableAttributedString()
        for (text, color, font) in parts {
            s.append(NSAttributedString(string: text, attributes: [.foregroundColor: color, .font: font]))
        }
        return s
    }
}
