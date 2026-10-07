import AppKit

/// While the setup card is up, notices when the fix may have landed: the
/// Terminal step's marker file appears, or the user switches apps (back from
/// Terminal, or after installing some other way). The coordinator decides
/// what a re-check means.
@MainActor
final class ProviderSetupWatcher {
    let markerURL: URL
    var onRecheck: (() -> Void)?

    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?

    init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("glance-setup"),
         pollInterval: TimeInterval = 1) {
        markerURL = directory.appendingPathComponent("step-finished")
        self.pollInterval = pollInterval
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMarker() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onRecheck?() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
    }

    /// Run a setup step in Terminal; its marker triggers the re-check.
    func runInTerminal(_ command: String) {
        try? FileManager.default.removeItem(at: markerURL)
        TerminalLauncher.run(command: command, marker: markerURL)
    }

    private func checkMarker() {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return }
        try? FileManager.default.removeItem(at: markerURL)
        onRecheck?()
    }
}
