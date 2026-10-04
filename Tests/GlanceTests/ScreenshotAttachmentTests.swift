import AppKit
import XCTest
@testable import Glance

@MainActor
final class ScreenshotAttachmentTests: XCTestCase {
    func testExplicitAttachmentRetriesCaptureAfterCachedPermissionDenial() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1kAAAAASUVORK5CYII=")!
        let image = NSImage(data: png)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let result = CaptureResult(image: image, pngData: png, displayIndex: 1,
                                   pixelWidth: 1, pixelHeight: 1)
        var captureCount = 0
        try await withCoordinator(capture: {
            captureCount += 1
            return result
        }) { overlay, backend in
            overlay.session.attachImage = true
            overlay.session.input = "Describe the screen"
            overlay.session.submit()
            await waitUntil { !backend.questions.isEmpty || overlay.session.turns.last?.failed == true }

            XCTAssertEqual(captureCount, 1)
            XCTAssertEqual(backend.questions, ["Describe the screen"])
            XCTAssertEqual(backend.images.first, png)
            XCTAssertNotNil(overlay.session.turns.last?.thumbnail)
        }
    }

    func testCaptureFailureDoesNotSendQuestionWithoutRequestedImage() async throws {
        try await withCoordinator(capture: { throw CaptureError.captureFailed("fixture failure") }) { overlay, backend in
            overlay.session.attachImage = true
            overlay.session.input = "Describe the screen"
            overlay.session.submit()
            await waitUntil { !backend.questions.isEmpty || overlay.session.turns.last?.failed == true }

            XCTAssertTrue(backend.questions.isEmpty)
            XCTAssertTrue(overlay.session.turns.last?.failed == true)
            XCTAssertTrue(overlay.session.turns.last?.answer.contains("fixture failure") == true)
            XCTAssertFalse(overlay.session.isWorking)
            XCTAssertEqual(overlay.session.input, "Describe the screen")
        }
    }

    func testDeniedPermissionDoesNotSendQuestionWithoutRequestedImage() async throws {
        try await withCoordinator(capture: { throw CaptureError.permissionDenied }) { overlay, backend in
            overlay.session.attachImage = true
            overlay.session.input = "Describe the screen"
            overlay.session.submit()
            await waitUntil { !backend.questions.isEmpty || overlay.session.turns.last?.failed == true }

            XCTAssertTrue(backend.questions.isEmpty)
            XCTAssertTrue(overlay.session.turns.last?.failed == true)
            XCTAssertFalse(overlay.session.isWorking)
        }
    }

    func testTextOnlyQuestionDoesNotAttemptScreenCapture() async throws {
        var captureCount = 0
        try await withCoordinator(capture: {
            captureCount += 1
            throw CaptureError.permissionDenied
        }) { overlay, backend in
            overlay.session.input = "Text only"
            overlay.session.submit()

            XCTAssertEqual(captureCount, 0)
            XCTAssertEqual(backend.questions, ["Text only"])
            XCTAssertNil(backend.images.first ?? nil)
        }
    }

    private func withCoordinator(capture: @escaping () async throws -> CaptureResult,
                                 check: (OverlayController, AttachmentBackend) async throws -> Void) async throws {
        _ = NSApplication.shared
        let previousBackend = Preferences.shared.askBackend
        let previousPreflight = ScreenCaptureService.preflight
        let previousProbe = ScreenCaptureService.probedGranted
        Preferences.shared.askBackend = .codex
        ScreenCaptureService.preflight = { false }
        ScreenCaptureService.probedGranted = false
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-attachment-test-\(UUID().uuidString)")
        let overlay = OverlayController()
        let backend = AttachmentBackend()
        let factory = AskBackendFactory(makeCodex: { _ in backend },
                                       codexStatus: { .ok(path: "/fixture/codex", version: "test") })
        let coordinator = AppCoordinator(
            backendLifecycle: AskBackendLifecycle(), overlay: overlay,
            automationProviderFactory: AutomationProviderFactory(codexStatus: { .notFound }),
            askBackendFactory: factory, taskStore: TaskStore(directory: directory),
            captureDisplay: capture
        )
        defer {
            overlay.dismiss()
            coordinator.endSession()
            Preferences.shared.askBackend = previousBackend
            ScreenCaptureService.preflight = previousPreflight
            ScreenCaptureService.probedGranted = previousProbe
            try? FileManager.default.removeItem(at: directory)
        }
        coordinator.replaceProviderServices(for: .codex)
        coordinator.summon()
        await waitUntil { overlay.session.submitHandler != nil }
        XCTAssertNotNil(overlay.session.submitHandler)
        try await check(overlay, backend)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(predicate(), "Attachment operation did not settle")
    }
}

private final class AttachmentBackend: AskBackend {
    var firstTokenTimeout: TimeInterval = 30
    var questions: [String] = []
    var images: [Data?] = []

    func startWarm() {}
    func shutdown() {}
    func ask(question: String, imagePNG: Data?, onEvent: @escaping (AskBackendEvent) -> Void) {
        questions.append(question)
        images.append(imagePNG)
    }
}
