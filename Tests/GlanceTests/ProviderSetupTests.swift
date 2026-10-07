import XCTest
@testable import Glance

final class ProviderSetupIssueTests: XCTestCase {

    func testClaudeNotFoundExplainsInstallAndSignIn() throws {
        let issue = try XCTUnwrap(ProviderSetupIssue.make(kind: .claude, availability: .notFound))
        XCTAssertTrue(issue.title.contains("Claude Code"))
        XCTAssertEqual(issue.copyCommand, "curl -fsSL https://claude.ai/install.sh | bash")
        XCTAssertEqual(issue.helpURL?.absoluteString, "https://code.claude.com/docs/en/setup")
        XCTAssertTrue(issue.steps.contains { $0.contains("`claude`") && $0.contains("sign in") })
        XCTAssertTrue(issue.steps.last?.contains("Try again") == true)
    }

    func testUnusableNamesThePathAndTheReason() throws {
        let issue = try XCTUnwrap(ProviderSetupIssue.make(
            kind: .claude, availability: .unusable(path: "/opt/homebrew/bin/claude", reason: "exit 1")))
        XCTAssertTrue(issue.detail.contains("/opt/homebrew/bin/claude"))
        XCTAssertTrue(issue.detail.contains("exit 1"))
        XCTAssertEqual(issue.copyCommand, "claude --version")
    }

    func testCodexGuidanceIsCodexSpecific() throws {
        let issue = try XCTUnwrap(ProviderSetupIssue.make(kind: .codex, availability: .notFound))
        XCTAssertTrue(issue.title.contains("Codex"))
        XCTAssertTrue(issue.steps.contains { $0.contains("`codex`") })
        XCTAssertFalse(issue.title.contains("Claude"))
    }

    func testNoIssueWhenAvailable() {
        XCTAssertNil(ProviderSetupIssue.make(kind: .claude, availability: .available(path: "/x", version: "2")))
    }
}

@MainActor
final class ProviderSetupOverlayTests: XCTestCase {

    private final class StubBackend: AskBackend {
        var firstTokenTimeout: TimeInterval = 30
        func startWarm() {}
        func shutdown() {}
        func ask(question: String, imagePNG: Data?, onEvent: @escaping (AskBackendEvent) -> Void) {}
    }

    func testMissingCLIOpensTheOverlayWithSetupStepsAndTryAgainRecovers() async {
        var status: CodexLocator.Status = .notFound
        let backend = StubBackend()
        let factory = AskBackendFactory(makeCodex: { _ in backend }, codexStatus: { status })
        let overlay = OverlayController()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-setup-test-\(UUID().uuidString)")
        let coordinator = AppCoordinator(
            backendLifecycle: AskBackendLifecycle(), overlay: overlay,
            automationProviderFactory: AutomationProviderFactory(codexStatus: { .notFound }),
            askBackendFactory: factory, taskStore: TaskStore(directory: directory))
        let previousBackend = Preferences.shared.askBackend
        Preferences.shared.askBackend = .codex
        defer {
            overlay.dismiss()
            coordinator.endSession()
            Preferences.shared.askBackend = previousBackend
            try? FileManager.default.removeItem(at: directory)
        }

        // Before: a modal NSAlert here would block this test forever.
        coordinator.summon()

        XCTAssertTrue(overlay.isVisible, "⌥Space must open the overlay even without a CLI")
        XCTAssertEqual(overlay.session.setupIssue?.title,
                       ProviderSetupIssue.make(kind: .codex, availability: .notFound)?.title)
        XCTAssertFalse(overlay.session.backendConnected)

        // User installs the CLI, presses Try again.
        status = .ok(path: "/fixture/codex", version: "1.0")
        overlay.session.setupRetryHandler?()
        let deadline = Date().addingTimeInterval(2)
        while overlay.session.setupIssue != nil || !overlay.session.backendConnected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(overlay.session.setupIssue)
        XCTAssertTrue(overlay.session.backendConnected)
        XCTAssertTrue(overlay.isVisible)
    }
}
