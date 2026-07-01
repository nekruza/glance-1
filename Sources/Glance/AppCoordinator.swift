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

    private var backend: ClaudeBackend?
    private var pendingImagePNG: Data?
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

        // FR7: Screen Recording gate before we try to capture.
        guard ScreenCaptureService.hasPermission else {
            PermissionOnboarding.promptForScreenRecording()
            return
        }

        // FR15 warm path: spawn the backend now so start/auth overlaps with the
        // user reading the overlay and typing.
        let backend = ClaudeBackend(binaryPath: path)
        backend.firstTokenTimeout = 30 // FR13
        backend.startWarm()
        self.backend = backend

        // FR8: capture the still BEFORE the overlay is on screen, then present.
        Task { [weak self] in
            guard let self else { return }
            do {
                let shot = try await ScreenCaptureService.captureActiveDisplay()
                self.pendingImagePNG = shot.pngData
                self.showOverlay()
            } catch CaptureError.permissionDenied {
                self.teardownBackend()
                PermissionOnboarding.promptForScreenRecording()
            } catch {
                self.teardownBackend()
                PermissionOnboarding.reportError(title: "Screen capture failed",
                                                 detail: error.localizedDescription)
            }
        }
    }

    private func showOverlay() {
        overlay.present()
        overlay.onSubmit { [weak self] question in
            self?.handleSubmit(question)
        }
    }

    // MARK: - Q&A

    private func handleSubmit(_ question: String) {
        guard let backend else {
            overlay.session.failTurn("Backend unavailable.")
            return
        }
        // Screenshot goes with the first question only (FR10); follow-ups reuse
        // the live session's context (FR12).
        let image = pendingImagePNG
        pendingImagePNG = nil

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

    /// FR4/FR9/FR12: end the overlay session — kill the backend process and drop
    /// the screenshot bytes. Next invocation starts fresh.
    private func endSession() {
        teardownBackend()
        pendingImagePNG = nil
    }

    private func teardownBackend() {
        backend?.shutdown()
        backend = nil
    }
}
