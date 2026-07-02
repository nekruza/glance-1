import AppKit
import ScreenCaptureKit
import Combine

/// Orchestrates the core flow (Core User Flow, FR1–FR16): hotkey → capture →
/// overlay → question → streamed answer → dismiss.
@MainActor
final class AppCoordinator {

    private let hotkey = HotkeyManager()
    private let overlay = OverlayController()
    private let prefs = Preferences.shared

    /// Opens the Settings window (wired to the status-item controller).
    var onOpenSettings: (() -> Void)?

    private var backend: ClaudeBackend?
    private var pendingImagePNG: Data?
    private var pendingCaptureLabel: String = ""
    private var claudeStatus: ClaudeLocator.Status = .notFound
    private var cancellables = Set<AnyCancellable>()

    func start() {
        claudeStatus = ClaudeLocator.check()

        hotkey.onFire = { [weak self] in self?.toggle() }
        hotkey.register(prefs.hotkey)

        // FR17: re-register whenever the user rebinds.
        prefs.$hotkey
            .dropFirst()
            .sink { [weak self] combo in self?.hotkey.register(combo) }
            .store(in: &cancellables)

        overlay.onDismiss = { [weak self] in self?.endSession() }

        // Warm ScreenCaptureKit's shareable-content cache so the first capture
        // isn't slow (helps FR2). Best-effort.
        Task { _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
    }

    /// Menu-driven summon (same as the hotkey).
    func summon() {
        if !overlay.isVisible { present() }
    }

    /// Current backend status for the menu's status line.
    func backendStatusLine() -> (connected: Bool, label: String) {
        let s = ClaudeLocator.check()
        if case .ok(_, let v) = s {
            return (true, "Claude CLI connected · " + shortVersion(v))
        }
        return (false, "Claude CLI not connected")
    }

    // MARK: - Invocation

    private func toggle() {
        if overlay.isVisible {
            overlay.dismiss() // FR4: hotkey again dismisses
        } else {
            present()
        }
    }

    private func present() {
        // FR16: refuse clearly if the CLI can't serve as a backend.
        claudeStatus = ClaudeLocator.check()
        guard case .ok(let path, _) = claudeStatus else {
            PermissionOnboarding.reportClaudeStatus(claudeStatus)
            return
        }

        // FR15 warm path: spawn the backend now so start/auth overlaps with the
        // user reading the overlay and typing. Reuse the live backend when
        // re-summoning — the conversation persists across dismissals.
        if backend == nil {
            let backend = ClaudeBackend(binaryPath: path)
            backend.firstTokenTimeout = 30 // FR13
            backend.startWarm()
            self.backend = backend
        }

        // Attachment defaults off, so don't block on Screen Recording — capture
        // opportunistically (FR8: before the overlay is shown) and open the
        // overlay either way. Permission is prompted only if the user attaches.
        Task { [weak self] in
            guard let self else { return }
            if ScreenCaptureService.hasPermission {
                if let shot = try? await ScreenCaptureService.captureActiveDisplay() {
                    self.pendingImagePNG = shot.pngData
                    self.pendingCaptureLabel = shot.displayLabel
                }
            }
            self.showOverlay()
        }
    }

    /// "2.1.197 (Claude Code)" → "claude 2.1.197".
    private func shortVersion(_ raw: String) -> String {
        let num = raw.split(separator: " ").first.map(String.init) ?? raw
        return "claude \(num)"
    }

    private func showOverlay() {
        overlay.present()
        // Reflect CLI connection in the footer (present() only reaches here when
        // the CLI is OK, so show the connected version).
        overlay.session.settingsHandler = { [weak self] in
            self?.overlay.dismiss()
            self?.onOpenSettings?()
        }
        overlay.session.historyHandler = { [weak self] summary in
            self?.resumeHistorySession(summary)
        }
        overlay.session.clearHandler = { [weak self] in
            self?.clearSession()
        }
        // Populate the History dropdown off the main thread (directory scan +
        // head parse of each candidate file).
        Task { [weak self] in
            let sessions = await Task.detached(priority: .utility) {
                SessionHistoryStore.recentSessions()
            }.value
            self?.overlay.session.historySessions = sessions
        }
        overlay.session.captureLabel = pendingCaptureLabel
        if case .ok(_, let version) = claudeStatus {
            overlay.session.backendConnected = true
            overlay.session.backendLabel = "Claude CLI connected · \(shortVersion(version))"
        } else {
            overlay.session.backendConnected = false
            overlay.session.backendLabel = "Claude CLI not connected"
        }
        overlay.onSubmit { [weak self] question in
            self?.handleSubmit(question)
        }
    }

    /// Clear button: drop the conversation (and any resumed session), start a
    /// fresh warm backend, and fall back to the idle prompt.
    private func clearSession() {
        teardownBackend()
        overlay.session.clearTranscript()
        guard case .ok(let path, _) = claudeStatus else { return }
        let backend = ClaudeBackend(binaryPath: path)
        backend.firstTokenTimeout = 30
        backend.startWarm()
        self.backend = backend
    }

    // MARK: - History resume

    /// Swap the backend for one that resumes the picked Claude CLI session and
    /// show its past transcript; follow-ups continue that conversation.
    private func resumeHistorySession(_ summary: SessionSummary) {
        guard case .ok(let path, _) = claudeStatus else { return }
        teardownBackend()

        let backend = ClaudeBackend(binaryPath: path,
                                    resumeSessionId: summary.id,
                                    resumeCwd: summary.cwd)
        // Resuming a large session (long transcript, project hooks) can take
        // far longer to first token than a fresh one.
        backend.firstTokenTimeout = 120
        backend.startWarm()
        self.backend = backend

        let url = summary.fileURL
        Task { [weak self] in
            let turns = await Task.detached(priority: .userInitiated) {
                SessionHistoryStore.loadTurns(from: url)
            }.value
            self?.overlay.session.loadTranscript(turns)
        }
    }

    // MARK: - Q&A

    private func handleSubmit(_ question: String) {
        guard let backend else {
            overlay.session.failTurn("Backend unavailable.")
            return
        }
        let attach = overlay.session.attachImage

        // Text-only (the default) — send immediately.
        guard attach else {
            send(question, image: nil, via: backend)
            return
        }

        // Attach requested but no Screen Recording permission → prompt, send
        // text-only this turn.
        guard ScreenCaptureService.hasPermission else {
            PermissionOnboarding.promptForScreenRecording()
            send(question, image: nil, via: backend)
            return
        }

        // First question: use the still captured at invocation (already clean).
        if let firstShot = pendingImagePNG {
            pendingImagePNG = nil
            send(question, image: firstShot, via: backend)
            return
        }

        // Follow-up: grab a FRESH shot of the current screen, hiding the overlay
        // so it isn't in the image (FR8).
        Task { [weak self] in
            guard let self else { return }
            let png = await self.captureExcludingOverlay()
            self.send(question, image: png, via: backend)
        }
    }

    /// Hide the overlay from capture, take a still, restore it.
    private func captureExcludingOverlay() async -> Data? {
        overlay.setHiddenForCapture(true)
        // Let the compositor drop the now-transparent panel before capturing.
        try? await Task.sleep(nanoseconds: 30_000_000) // 30 ms
        let png = try? await ScreenCaptureService.captureActiveDisplay().pngData
        overlay.setHiddenForCapture(false)
        return png
    }

    private func send(_ question: String, image: Data?, via backend: ClaudeBackend) {
        backend.ask(question: question, imagePNG: image) { [weak self] event in
            guard let self else { return }
            switch event {
            case .token(let text): self.overlay.session.appendToken(text)
            case .completed:        self.overlay.session.completeTurn()
            case .failed(let msg):  self.overlay.session.failTurn(msg)
            }
        }
    }

    // MARK: - Teardown

    /// Overlay dismissed. Keep the backend and transcript — the conversation
    /// survives until the user clears it (trash) — but drop the screenshot
    /// bytes (FR9); the next summon captures a fresh one.
    private func endSession() {
        pendingImagePNG = nil
        // Attaching is an explicit, per-summon opt-in — never carry it over.
        overlay.session.attachImage = false
    }

    /// App is quitting: don't leave an orphaned claude process behind.
    func shutdown() {
        teardownBackend()
    }

    private func teardownBackend() {
        backend?.shutdown()
        backend = nil
    }
}
