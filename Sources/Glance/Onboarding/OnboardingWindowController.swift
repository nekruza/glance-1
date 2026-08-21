import AppKit
import SwiftUI

/// First-launch tour window. Shown once (gated on `Preferences.shared
/// .onboardingCompleted`) and re-openable from the menu bar's "Welcome Tour…".
/// Closing the window at any page counts as completing — the tour must never
/// nag on relaunch.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?

    /// True until the user has finished or dismissed the tour once.
    static var shouldShow: Bool { !Preferences.shared.onboardingCompleted }

    /// First-launch entry point: present only if the tour was never seen.
    func presentIfNeeded() {
        guard Self.shouldShow else { return }
        present()
    }

    /// Unconditional entry point (menu bar "Welcome Tour…").
    func present() {
        if let window {
            AppActivation.acquire("onboarding")
            window.makeKeyAndOrderFront(nil)
            return
        }
        let prefs = Preferences.shared
        let pages = OnboardingCatalog.pages(askHotkey: prefs.hotkey.displayString,
                                            taskHotkey: prefs.taskHotkey.displayString)
        let hosting = NSHostingController(rootView: OnboardingView(pages: pages) { [weak self] in
            self?.finish()
        })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Glance"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        AppActivation.acquire("onboarding")
        window.makeKeyAndOrderFront(nil)
        // The .accessory → .regular flip can order a just-shown window out
        // during launch; re-assert front once the policy change has settled.
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func finish() {
        Preferences.shared.onboardingCompleted = true
        window?.close() // cleanup happens in windowWillClose
    }

    func windowWillClose(_ notification: Notification) {
        Preferences.shared.onboardingCompleted = true
        window = nil
        AppActivation.release("onboarding")
    }
}
