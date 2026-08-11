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

    func testCoordinatorDismissalShutsDownItsActiveBackend() {
        let lifecycle = AskBackendLifecycle()
        let backend = BackendSpy()
        lifecycle.install(backend)
        let coordinator = AppCoordinator(backendLifecycle: lifecycle)

        coordinator.endSession()

        XCTAssertEqual(backend.shutdownCount, 1)
        XCTAssertNil(lifecycle.backend)
    }
}

private final class BackendSpy: AskBackend {
    var firstTokenTimeout: TimeInterval = 30
    private(set) var shutdownCount = 0

    func startWarm() {}
    func ask(question: String, imagePNG: Data?, onEvent: @escaping (AskBackendEvent) -> Void) {}
    func shutdown() { shutdownCount += 1 }
}
