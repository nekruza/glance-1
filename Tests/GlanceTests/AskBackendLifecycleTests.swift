import XCTest
@testable import Glance

@MainActor
final class AskBackendLifecycleTests: XCTestCase {
    func testProviderReplacementInvalidatesAwaitLeaseAndShutsDownOldBackend() throws {
        let lifecycle = AskBackendLifecycle()
        let oldBackend = BackendSpy()
        let newBackend = BackendSpy()
        lifecycle.install(oldBackend)
        let oldLease = try XCTUnwrap(lifecycle.lease(for: oldBackend))

        lifecycle.install(newBackend)

        XCTAssertEqual(oldBackend.shutdownCount, 1)
        XCTAssertFalse(lifecycle.isCurrent(oldLease))
        XCTAssertTrue(lifecycle.backend === newBackend)
    }

    func testDismissalShutdownInvalidatesCallbacksAndStopsActiveBackend() throws {
        let lifecycle = AskBackendLifecycle()
        let backend = BackendSpy()
        lifecycle.install(backend)
        let inFlightLease = try XCTUnwrap(lifecycle.lease(for: backend))

        lifecycle.shutdown()

        XCTAssertEqual(backend.shutdownCount, 1)
        XCTAssertNil(lifecycle.backend)
        XCTAssertFalse(lifecycle.isCurrent(inFlightLease))
    }

    func testCoordinatorDismissalClearsVisibleTranscriptAndShutsDownItsActiveBackend() {
        let lifecycle = AskBackendLifecycle()
        let backend = BackendSpy()
        lifecycle.install(backend)
        let overlay = OverlayController()
        let coordinator = AppCoordinator(backendLifecycle: lifecycle, overlay: overlay)
        overlay.session.turns = [
            OverlaySession.Turn(question: "Old question", answer: "Old answer")
        ]
        overlay.session.input = "Old draft"
        overlay.session.suggestions = ["Old follow-up"]

        coordinator.endSession()

        XCTAssertEqual(backend.shutdownCount, 1)
        XCTAssertNil(lifecycle.backend)
        XCTAssertTrue(overlay.session.turns.isEmpty)
        XCTAssertTrue(overlay.session.input.isEmpty)
        XCTAssertTrue(overlay.session.suggestions.isEmpty)
    }

    func testCoordinatorProviderSwitchShutsDownAskBackendBeforeReplacingTaskServices() throws {
        let lifecycle = AskBackendLifecycle()
        let backend = BackendSpy()
        lifecycle.install(backend)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-lifecycle-switch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = LifecycleAutomationProvider()
        let factory = AutomationProviderFactory(
            makeClaude: { _, _ in provider },
            makeCodex: { _, _ in provider },
            claudeStatus: { .ok(path: "/test/claude", version: "test") },
            codexStatus: { .ok(path: "/test/codex", version: "test") }
        )
        let coordinator = AppCoordinator(
            backendLifecycle: lifecycle, overlay: OverlayController(),
            automationProviderFactory: factory, taskStore: TaskStore(directory: directory)
        )

        coordinator.replaceProviderServices(for: .codex)

        XCTAssertEqual(backend.shutdownCount, 1)
        XCTAssertNil(lifecycle.backend)
        XCTAssertEqual(coordinator.taskOverlay?.session.providerKind, .codex)
    }
}

private final class BackendSpy: AskBackend {
    var firstTokenTimeout: TimeInterval = 30
    private(set) var shutdownCount = 0

    func startWarm() {}
    func ask(question: String, imagePNG: Data?, onEvent: @escaping (AskBackendEvent) -> Void) {}
    func shutdown() { shutdownCount += 1 }
}

private final class LifecycleAutomationProvider: AutomationProvider {
    let descriptor = AutomationProviderDescriptor(kind: .codex, version: "test")

    func runText(_ request: AutomationRequest,
                 onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        AutomationCancellation()
    }

    func startRun(_ request: AutomationRunRequest,
                  onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        AutomationCancellation()
    }

    func runComposio(_ request: ComposioAutomationRequest, token: String,
                     onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        AutomationCancellation()
    }

    func cancelAll() {}
}
