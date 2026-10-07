import AppKit

/// FR7 (Screen Recording TCC) and FR16 (local CLI health) onboarding dialogs.
/// These are rare error paths, so a standard NSAlert is the clearest UX. Never
/// fail silently.
@MainActor
enum PermissionOnboarding {

    private static let screenRecordingSettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    /// FR7: guide the user to grant Screen Recording, deep-linking to the exact
    /// System Settings pane. Also triggers the system's own prompt once.
    static func promptForScreenRecording() {
        _ = ScreenCaptureService.requestPermission() // fire the OS prompt once

        let alert = NSAlert()
        alert.messageText = "Glance needs Screen Recording permission"
        alert.informativeText = """
        To answer questions about your screen, Glance captures a still image of \
        the active display when you invoke it.

        Enable Glance under System Settings → Privacy & Security → Screen \
        Recording, then relaunch the app.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        activateForDialog()
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: screenRecordingSettingsURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    static func reportError(title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        activateForDialog()
        alert.runModal()
    }

    /// Accessory apps aren't active by default; briefly activate so modal
    /// dialogs come to the front.
    private static func activateForDialog() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
