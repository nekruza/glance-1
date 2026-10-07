import XCTest
@testable import Glance

final class ProviderSetupIssueTests: XCTestCase {

    func testClaudeNotFoundExplainsInstallAndSignIn() throws {
        let issue = try XCTUnwrap(ProviderSetupIssue.make(kind: .claude, availability: .notFound))
        XCTAssertTrue(issue.title.contains("Claude Code"))
        XCTAssertEqual(issue.copyCommand, "curl -fsSL https://claude.ai/install.sh | bash")
        XCTAssertEqual(issue.helpURL?.absoluteString, "https://code.claude.com/docs/en/setup")
        XCTAssertEqual(issue.problem, .notInstalled)
        XCTAssertEqual(issue.terminalAction?.label, "Install in Terminal")
        XCTAssertEqual(issue.terminalAction?.command, "curl -fsSL https://claude.ai/install.sh | bash")
        XCTAssertTrue(issue.steps.last?.contains("Try again") == true)
    }

    func testSignedOutOffersSignInWithTheFoundBinary() {
        let issue = ProviderSetupIssue.signedOut(kind: .claude, binaryPath: "/Users/me/.local/bin/claude")
        XCTAssertEqual(issue.problem, .signedOut)
        XCTAssertTrue(issue.title.contains("Sign in"))
        XCTAssertEqual(issue.copyCommand, "claude auth login")
        XCTAssertEqual(issue.terminalAction?.label, "Sign in")
        // Run the exact binary Glance found — it may not be on Terminal's PATH.
        XCTAssertEqual(issue.terminalAction?.command, "'/Users/me/.local/bin/claude' auth login")

        let codex = ProviderSetupIssue.signedOut(kind: .codex, binaryPath: "/opt/homebrew/bin/codex")
        XCTAssertEqual(codex.terminalAction?.command, "'/opt/homebrew/bin/codex' login")
    }

    func testUnusableNamesThePathAndTheReason() throws {
        let issue = try XCTUnwrap(ProviderSetupIssue.make(
            kind: .claude, availability: .unusable(path: "/opt/homebrew/bin/claude", reason: "exit 1")))
        XCTAssertTrue(issue.detail.contains("/opt/homebrew/bin/claude"))
        XCTAssertTrue(issue.detail.contains("exit 1"))
        XCTAssertEqual(issue.copyCommand, "claude --version")
        XCTAssertEqual(issue.problem, .broken)
        XCTAssertEqual(issue.terminalAction?.command, "'/opt/homebrew/bin/claude' --version")
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

final class SetupHelpersTests: XCTestCase {

    func testTerminalScriptRunsTheCommandThenLeavesTheMarker() {
        let marker = URL(fileURLWithPath: "/tmp/glance setup/done")
        let script = TerminalLauncher.script(command: "'/x/claude' auth login", marker: marker)
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh -l\n"))
        let run = script.range(of: "'/x/claude' auth login")!
        let touch = script.range(of: "touch '/tmp/glance setup/done'")!
        XCTAssertLessThan(run.lowerBound, touch.lowerBound, "marker only after the step ends")
    }

    func testShellQuotingSurvivesQuotesInPaths() {
        XCTAssertEqual(TerminalLauncher.quote("/a/it's/claude"), "'/a/it'\\''s/claude'")
    }

    func testAuthStatusParsing() {
        XCTAssertEqual(AuthStatus.parseClaude(#"{"loggedIn": true, "email": "a@b"}"#), true)
        XCTAssertEqual(AuthStatus.parseClaude(#"{"loggedIn": false}"#), false)
        XCTAssertNil(AuthStatus.parseClaude("garbage"))
        XCTAssertEqual(AuthStatus.parseCodex(exitCode: 0, output: "Logged in using ChatGPT"), true)
        XCTAssertEqual(AuthStatus.parseCodex(exitCode: 1, output: "Not logged in"), false)
    }

    func testAuthErrorsAreRecognised() {
        XCTAssertTrue(ClaudeBackend.isAuthError("Invalid API key · Please run /login"))
        XCTAssertTrue(ClaudeBackend.isAuthError("Not logged in"))
        XCTAssertFalse(ClaudeBackend.isAuthError("Usage limit reached"))
        XCTAssertFalse(ClaudeBackend.isAuthError(nil))
    }

    @MainActor
    func testWatcherRechecksWhenTheTerminalStepLeavesItsMarker() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glance-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = ProviderSetupWatcher(directory: dir, pollInterval: 0.05)
        var rechecks = 0
        watcher.onRecheck = { rechecks += 1 }
        watcher.start()
        defer { watcher.stop() }

        FileManager.default.createFile(atPath: watcher.markerURL.path, contents: nil)
        let deadline = Date().addingTimeInterval(2)
        while rechecks == 0, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(rechecks, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: watcher.markerURL.path), "marker consumed")
    }
}

@MainActor
final class ProviderSetupOverlayTests: XCTestCase {

    private final class StubBackend: AskBackend {
        var firstTokenTimeout: TimeInterval = 30
        var reply: AskBackendEvent?
        func startWarm() {}
        func shutdown() {}
        func ask(question: String, imagePNG: Data?, onEvent: @escaping (AskBackendEvent) -> Void) {
            if let reply { onEvent(reply) }
        }
    }

    func testSignedOutReplyShowsSignInAndKeepsTheQuestionThenRecovers() async {
        var built: [StubBackend] = []
        let factory = AskBackendFactory(makeCodex: { _ in
            let b = StubBackend(); b.reply = .signedOut; built.append(b); return b
        }, codexStatus: { .ok(path: "/fixture/codex", version: "1.0") })
        let overlay = OverlayController()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-signin-test-\(UUID().uuidString)")
        let coordinator = AppCoordinator(
            backendLifecycle: AskBackendLifecycle(), overlay: overlay,
            automationProviderFactory: AutomationProviderFactory(codexStatus: { .notFound }),
            askBackendFactory: factory, taskStore: TaskStore(directory: directory))
        var signedIn = false
        coordinator.authStatusCheck = { _, _ in signedIn }
        let previousBackend = Preferences.shared.askBackend
        Preferences.shared.askBackend = .codex
        defer {
            overlay.dismiss()
            coordinator.endSession()
            Preferences.shared.askBackend = previousBackend
            try? FileManager.default.removeItem(at: directory)
        }

        coordinator.replaceProviderServices(for: .codex)
        coordinator.summon()
        await waitUntil { overlay.session.submitHandler != nil }
        overlay.session.input = "What's on my screen?"
        overlay.session.submit()
        await waitUntil { overlay.session.setupIssue != nil }

        XCTAssertEqual(overlay.session.setupIssue?.problem, .signedOut)
        XCTAssertEqual(overlay.session.input, "What's on my screen?", "question kept for after sign-in")
        XCTAssertTrue(overlay.session.turns.isEmpty)

        // Still signed out: a re-check leaves the card up.
        overlay.session.setupRetryHandler?()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(overlay.session.setupIssue?.problem, .signedOut)

        // Signed in: the card clears and a fresh CLI process picks up the login.
        signedIn = true
        let before = built.count
        overlay.session.setupRetryHandler?()
        await waitUntil { overlay.session.setupIssue == nil }
        XCTAssertNil(overlay.session.setupIssue)
        XCTAssertGreaterThan(built.count, before)
        XCTAssertEqual(overlay.session.input, "What's on my screen?")
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
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
