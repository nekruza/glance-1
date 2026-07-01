import AppKit

// Executable entry point. A menu-bar (accessory) app has no main storyboard;
// we bootstrap NSApplication manually and hand off to AppDelegate.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Keep the delegate alive for the process lifetime.
    withExtendedLifetime(delegate) {
        app.run()
    }
}
