import XCTest
import AppKit
@testable import Glance

@MainActor
final class BackendTesterLifecycleTests: XCTestCase {
    func testProviderChangeCancelsTestSettlesLoadingAndRejectsStaleCallback() {
        var callbacks: [AskBackendKind: (BackendTester.Outcome) -> Void] = [:]
        var cancelled: [AskBackendKind] = []
        let session = BackendTestSession { kind, _, completion in
            callbacks[kind] = completion
            return AutomationCancellation { cancelled.append(kind) }
        }

        session.start(kind: .claude)
        XCTAssertTrue(session.isTesting)

        session.providerDidChange(to: .codex)
        callbacks[.claude]?(.failure("stale Claude failure"))

        XCTAssertEqual(cancelled, [.claude])
        XCTAssertFalse(session.isTesting)
        XCTAssertNil(session.outcome)

        session.start(kind: .codex)
        callbacks[.codex]?(.failure("current Codex failure"))
        guard case .failure(let message) = session.outcome else {
            return XCTFail("Expected the current provider's test outcome")
        }
        XCTAssertEqual(message, "current Codex failure")
    }

    func testClosingSettingsCancelsItsOwnedBackendTest() {
        var cancelCount = 0
        var session: BackendTestSession? = BackendTestSession { _, _, _ in
            AutomationCancellation { cancelCount += 1 }
        }
        session?.start(kind: .codex)

        session = nil

        XCTAssertEqual(cancelCount, 1)
    }

    /// Break protected: the reusable Tasks window retains its hosting view and
    /// settings state after the traffic-light close. The real window delegate
    /// boundary must cancel the health-check child even though neither the
    /// controller nor session deinitializes.
    func testClosingRetainedTasksWindowCancelsRunningBackendTest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backend-test-window-close-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-codex")
        let script = #"""
        #!/bin/sh
        trap '' TERM
        printf '%s' "$$" > "$(dirname "$0")/pid"
        exec /bin/sleep 60
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let testSession = BackendTestSession { kind, timeout, completion in
            BackendTester.test(
                command: .init(executablePath: executable.path, arguments: []),
                kind: kind, timeout: timeout, completion: completion
            )
        }
        let storeDirectory = directory.appendingPathComponent("store", isDirectory: true)
        let store = TaskStore(directory: storeDirectory)
        let provider = WindowCloseAutomationProvider()
        let controller = TaskOverlayController(
            store: store,
            runner: TaskRunner(store: store, provider: provider),
            ai: TaskAI(provider: provider),
            ingest: ComposioIngest(provider: provider),
            backendTestSession: testSession
        )
        controller.session.showSettings = true
        testSession.start(kind: .codex, timeout: 30)
        controller.present()

        let pidURL = directory.appendingPathComponent("pid")
        waitForFile(pidURL)
        let processID = try XCTUnwrap(pid_t(try String(contentsOf: pidURL, encoding: .utf8)))
        defer { Darwin.kill(processID, SIGKILL) }
        let window = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == "Glance Tasks" })

        window.close()

        waitForProcessExit(processID, timeout: 1.5)
        XCTAssertFalse(testSession.isTesting)
        XCTAssertFalse(controller.isVisible)
    }

    func testCancellingBackendTestForceKillsAChildThatIgnoresTermination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backend-test-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-codex")
        let script = #"""
        #!/bin/sh
        trap '' TERM
        printf '%s' "$$" > "$(dirname "$0")/pid"
        exec /bin/sleep 60
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let staleOutcome = expectation(description: "cancelled test emits no outcome")
        staleOutcome.isInverted = true
        let cancellation = BackendTester.test(
            command: .init(executablePath: executable.path, arguments: []),
            kind: .codex, timeout: 30
        ) { _ in staleOutcome.fulfill() }
        let pidURL = directory.appendingPathComponent("pid")
        waitForFile(pidURL)
        let processID = try XCTUnwrap(pid_t(try String(contentsOf: pidURL, encoding: .utf8)))
        defer { Darwin.kill(processID, SIGKILL) }

        cancellation.cancel()

        waitForProcessExit(processID, timeout: 1.5)
        wait(for: [staleOutcome], timeout: 0.2)
    }

    func testQuotaCopyIsProviderSpecific() {
        XCTAssertEqual(BackendTester.friendly("quota exhausted", kind: .codex),
                       "Usage limit reached. Try again later.")
        XCTAssertEqual(BackendTester.friendly("quota exhausted", kind: .claude),
                       "Usage limit reached (Pro/Max quota).")
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    private func waitForProcessExit(_ processID: pid_t, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Darwin.kill(processID, 0) == -1, errno == ESRCH { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Process \(processID) did not exit")
    }
}

private final class WindowCloseAutomationProvider: AutomationProvider {
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
