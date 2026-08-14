import XCTest
@testable import Glance

@MainActor
final class ProviderGenerationTests: XCTestCase {
    func testCoordinatorConfiguresCodexAskWithTaskCaptureInstructions() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-codex-ask-instructions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = fixtureDirectory.appendingPathComponent("fake-codex")
        let script = #"""
        #!/bin/sh
        fixture_dir="$(dirname "$0")"
        printf '%s\n' "$@" > "$fixture_dir/args"
        cat > "$fixture_dir/stdin"
        printf '%s\n' '{"type":"thread.started","thread_id":"task-capture-thread"}'
        printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Added.\n```glance-task\n{\"title\":\"Fix the Codex overlay\",\"taskKind\":\"code\"}\n```"}}'
        printf '%s\n' '{"type":"turn.completed","usage":{}}'
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let storeDirectory = fixtureDirectory.appendingPathComponent("store", isDirectory: true)
        let store = TaskStore(directory: storeDirectory)
        let overlay = OverlayController()
        let provider = HoldingAutomationProvider(kind: .codex)
        let automationFactory = AutomationProviderFactory(
            makeClaude: { _, _ in HoldingAutomationProvider(kind: .claude) },
            makeCodex: { _, _ in provider },
            claudeStatus: { .ok(path: "/test/claude", version: "test") },
            codexStatus: { .ok(path: executable.path, version: "test") }
        )
        let askFactory = AskBackendFactory(
            makeClaude: { _ in RecordingAskBackend(kind: .claude, recorder: ProviderLaunchRecorder()) },
            makeCodex: { CodexBackend(binaryPath: $0) },
            claudeStatus: { .ok(path: "/test/claude", version: "test") },
            codexStatus: { .ok(path: executable.path, version: "test") }
        )
        let coordinator = AppCoordinator(
            backendLifecycle: AskBackendLifecycle(), overlay: overlay,
            automationProviderFactory: automationFactory,
            askBackendFactory: askFactory, taskStore: store
        )
        let previousBackend = Preferences.shared.askBackend
        Preferences.shared.askBackend = .codex
        defer {
            Preferences.shared.askBackend = previousBackend
            coordinator.endSession()
            overlay.dismiss()
        }

        coordinator.replaceProviderServices(for: .codex)
        coordinator.summon()
        waitUntil { overlay.session.submitHandler != nil }
        overlay.session.input = "Add a task from this screenshot"
        overlay.session.submit()

        waitUntil { store.tasks.contains { $0.title == "Fix the Codex overlay" } }
        let arguments = try String(contentsOf: fixtureDirectory.appendingPathComponent("args"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let configIndex = try XCTUnwrap(arguments.firstIndex(of: "-c"))
        let override = arguments[configIndex + 1]
        let prefix = "developer_instructions="
        XCTAssertTrue(override.hasPrefix(prefix))
        let encodedInstructions = String(override.dropFirst(prefix.count))
        let instructions = try JSONDecoder().decode(String.self, from: Data(encodedInstructions.utf8))
        XCTAssertEqual(instructions, TaskCapture.systemPrompt)
        XCTAssertEqual(arguments.last, "-")
        XCTAssertEqual(try String(contentsOf: fixtureDirectory.appendingPathComponent("stdin"), encoding: .utf8),
                       "Add a task from this screenshot")
        XCTAssertEqual(store.tasks.first?.taskKind, .code)
    }

    func testCoordinatorCodexSelectionLaunchesOnlyCodexAcrossAIRequests() throws {
        let launches = ProviderLaunchRecorder()
        let harness = try CoordinatorProviderCoverageHarness(launches: launches)
        defer {
            harness.removeStore()
            harness.overlay.dismiss()
        }

        let previousBackend = Preferences.shared.askBackend
        let previousKey = Preferences.shared.composioKey
        let previousURL = Preferences.shared.composioURL
        Preferences.shared.askBackend = .codex
        Preferences.shared.composioKey = "test-composio-token"
        Preferences.shared.composioURL = "https://connect.composio.dev/mcp"
        defer {
            Preferences.shared.askBackend = previousBackend
            Preferences.shared.composioKey = previousKey
            Preferences.shared.composioURL = previousURL
        }

        // This is the production service-bundle replacement path. Its factory
        // must build only Codex before task AI, suggestions, and Composio are
        // reached through the coordinator-owned UI services.
        harness.coordinator.replaceProviderServices(for: .codex)

        harness.coordinator.summon()
        waitUntil { launches.count(for: .codex, role: .askWarm) == 1 }
        waitUntil { harness.overlay.session.submitHandler != nil }

        harness.overlay.session.input = "What is on screen?"
        harness.overlay.session.submit()

        guard let board = harness.coordinator.taskOverlay?.session else {
            return XCTFail("Coordinator should expose the rebuilt task board")
        }
        board.decomposeText = "Ship the provider switch"
        board.runDecompose()

        let connectionsFinished = expectation(description: "Codex lists Composio connections")
        board.listConnections { connections, error in
            XCTAssertNil(error)
            XCTAssertTrue(connections?.isEmpty == true)
            connectionsFinished.fulfill()
        }

        let transcriber = MeetingTranscriber()
        transcriber.summaryProviderLease = { [weak coordinator = harness.coordinator] in
            coordinator?.currentAutomationProviderLease()
        }
        let notesURL = harness.storeDirectory.appendingPathComponent("meeting.md")
        try "Meeting transcript".write(to: notesURL, atomically: true, encoding: .utf8)
        transcriber.summarizeForTesting("Discussed the selected provider.", into: notesURL)

        wait(for: [connectionsFinished], timeout: 1)

        XCTAssertEqual(launches.count(for: .claude), 0,
                       "Codex selection must never construct or launch Claude: \(launches.summary())")
        XCTAssertEqual(launches.count(for: .codex, role: .automationConstruction), 1)
        XCTAssertEqual(launches.count(for: .codex, role: .askConstruction), 1)
        XCTAssertEqual(launches.count(for: .codex, role: .askWarm), 1)
        XCTAssertEqual(launches.count(for: .codex, role: .askTurn), 1)
        for context in ["taskAI", "suggestions", "composio", "meetingSummary"] {
            XCTAssertEqual(launches.count(for: .codex, role: .automation, context: context), 1,
                           "\(context) must launch Codex exactly once: \(launches.summary())")
            XCTAssertEqual(launches.count(for: .claude, role: .automation, context: context), 0,
                           "\(context) must not launch Claude: \(launches.summary())")
        }
    }

    func testMeetingSummaryUsesCurrentCodexProvider() {
        let provider = SummaryAutomationProvider(kind: .codex)
        let transcriber = MeetingTranscriber()
        transcriber.summaryProvider = { provider }

        transcriber.summarizeForTesting("Meeting text")

        XCTAssertTrue(provider.requestedPrompts.first?.contains("Meeting text") == true)
    }

    func testProviderSwitchDropsQueuedMeetingSummaryBeforeItWritesOrAutoIngests() throws {
        let harness = try CoordinatorProviderHarness()
        defer { harness.removeStore() }
        let notesURL = harness.storeDirectory.appendingPathComponent("meeting.md")
        let originalNotes = "# Meeting\n\nTranscript"
        try originalNotes.write(to: notesURL, atomically: true, encoding: .utf8)
        let transcriber = MeetingTranscriber()
        transcriber.summaryProviderLease = { harness.coordinator.currentAutomationProviderLease() }
        var summarizedURLs: [URL] = []
        transcriber.onSummarized = { summarizedURLs.append($0) }

        harness.coordinator.replaceProviderServices(for: .claude)
        transcriber.summarizeForTesting("Meeting text", into: notesURL)
        waitUntil { harness.claude.textRequestCount == 1 }

        harness.coordinator.replaceProviderServices(for: .codex)
        // The harness intentionally reuses its Claude double. This catches a
        // mere provider-identity check: an old callback must remain stale even
        // after the user selects the same provider kind again.
        harness.coordinator.replaceProviderServices(for: .claude)
        harness.claude.emitText([.text("## Summary\nOld Claude notes"), .completed])
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(try String(contentsOf: notesURL, encoding: .utf8), originalNotes)
        XCTAssertTrue(summarizedURLs.isEmpty)
    }

    func testCurrentProviderMeetingSummaryWritesNotesAndTriggersAutoIngest() throws {
        let harness = try CoordinatorProviderHarness()
        defer { harness.removeStore() }
        let notesURL = harness.storeDirectory.appendingPathComponent("meeting.md")
        try "# Meeting\n\nTranscript".write(to: notesURL, atomically: true, encoding: .utf8)
        let transcriber = MeetingTranscriber()
        transcriber.summaryProviderLease = { harness.coordinator.currentAutomationProviderLease() }
        var summarizedURLs: [URL] = []
        transcriber.onSummarized = { summarizedURLs.append($0) }

        harness.coordinator.replaceProviderServices(for: .claude)
        transcriber.summarizeForTesting("Meeting text", into: notesURL)
        waitUntil { harness.claude.textRequestCount == 1 }
        harness.claude.emitText([.text("## Summary\nCurrent Claude notes"), .completed])
        waitUntil { summarizedURLs == [notesURL] }

        let saved = try String(contentsOf: notesURL, encoding: .utf8)
        XCTAssertTrue(saved.hasPrefix("## Summary\nCurrent Claude notes\n\n---\n\n# Meeting"))
    }

    func testCoordinatorExposesCurrentCodexProviderForMeetingSummary() throws {
        let harness = try CoordinatorProviderHarness()
        defer { harness.removeStore() }

        harness.coordinator.replaceProviderServices(for: .codex)

        XCTAssertEqual(harness.coordinator.currentAutomationProvider?.descriptor.kind, .codex)
    }

    func testProviderChangeCancelsTaskAndComposioWorkBeforeInstallingCodex() throws {
        let harness = try CoordinatorProviderHarness()
        defer { harness.removeStore() }
        let originalKey = Preferences.shared.composioKey
        Preferences.shared.composioKey = "test-key"
        defer { Preferences.shared.composioKey = originalKey }

        harness.coordinator.replaceProviderServices(for: .claude)
        let task = harness.store.add(TaskItem(title: "Keep working"))
        harness.coordinator.taskRunner?.startRun(taskId: task.id)
        harness.coordinator.taskOverlay?.session.pull(.builtin(.jira))
        waitUntil { harness.claude.composioRequestCount == 1 }

        harness.coordinator.replaceProviderServices(for: .codex)

        XCTAssertEqual(harness.claude.cancelAllCount, 1)
        XCTAssertEqual(harness.store.runs(for: task.id).first?.failureReason, "AI provider changed.")
        XCTAssertEqual(harness.coordinator.taskOverlay?.session.providerKind, .codex)
    }

    func testProviderSwitchClearsTransientBoardStateAndSettlesSuppressedConnectionRefresh() throws {
        let harness = try CoordinatorProviderHarness(suppressClaudeCallbacksOnCancel: true)
        defer { harness.removeStore() }
        let previousKey = Preferences.shared.composioKey
        let previousURL = Preferences.shared.composioURL
        Preferences.shared.composioKey = "test-composio-token"
        Preferences.shared.composioURL = "https://connect.composio.dev/mcp"
        defer {
            Preferences.shared.composioKey = previousKey
            Preferences.shared.composioURL = previousURL
        }
        let taskID = UUID()
        var completions: [([ComposioIngest.Connection]?, String?)] = []

        harness.coordinator.replaceProviderServices(for: .claude)
        guard let board = harness.coordinator.taskOverlay?.session else {
            return XCTFail("Expected task board session")
        }
        board.pullStatus = "Composio call failed (Claude exited 1)."
        board.sendError[taskID] = "Claude could not send this draft."
        board.listConnections { completions.append(($0, $1)) }
        waitUntil { harness.claude.composioRequestCount == 1 }

        harness.coordinator.replaceProviderServices(for: .codex)

        XCTAssertNil(board.pullStatus)
        XCTAssertTrue(board.sendError.isEmpty)
        XCTAssertEqual(completions.count, 1,
                       "A provider switch must settle a settings refresh even when cancellation suppresses the CLI callback")
        XCTAssertNil(completions.first?.0)
        XCTAssertNil(completions.first?.1)
        harness.claude.emitComposio([.failed("stale Claude failure")])
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(completions.count, 1, "A stale provider callback must not settle the new UI twice")
    }

    /// Break protected: the scheduled briefing claims today's run before its
    /// calendar freshness pull completes. A provider replacement must carry
    /// that continuation to the new service bundle even when cancellation
    /// suppresses the old CLI callback, or the whole workday is skipped.
    func testProviderSwitchResumesScheduledBriefingAfterSuppressedCalendarPull() throws {
        let harness = try CoordinatorProviderHarness(suppressClaudeCallbacksOnCancel: true)
        defer { harness.removeStore() }
        let prefs = Preferences.shared
        let previous = (
            key: prefs.composioKey,
            enabledSources: prefs.enabledSources,
            briefingEnabled: prefs.briefingEnabled,
            briefingMinutes: prefs.briefingMinutes,
            briefingLastRun: prefs.briefingLastRun,
            prepEnabled: prefs.prepAutopilotEnabled
        )
        defer {
            prefs.composioKey = previous.key
            prefs.enabledSources = previous.enabledSources
            prefs.briefingEnabled = previous.briefingEnabled
            prefs.briefingMinutes = previous.briefingMinutes
            prefs.briefingLastRun = previous.briefingLastRun
            prefs.prepAutopilotEnabled = previous.prepEnabled
        }
        prefs.composioKey = "test-composio-token"
        prefs.setFetch(.calendar, true)
        prefs.briefingEnabled = true
        prefs.briefingMinutes = 9 * 60
        prefs.briefingLastRun = nil
        prefs.prepAutopilotEnabled = false

        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 8
        components.day = 14 // Friday
        components.hour = 10
        let now = try XCTUnwrap(components.date)
        let autopilot = Autopilot(now: { now })

        harness.coordinator.replaceProviderServices(for: .claude)
        let board = try XCTUnwrap(harness.coordinator.taskOverlay?.session)
        autopilot.tick(session: board, notify: { _, _ in })
        waitUntil { harness.claude.composioRequestCount == 1 }
        XCTAssertEqual(harness.claude.textRequestCount, 0)

        harness.coordinator.replaceProviderServices(for: .codex)

        waitUntil { harness.codex.textRequestCount == 1 }
        XCTAssertEqual(board.providerKind, .codex)
        XCTAssertTrue(board.store.tasks.isEmpty,
                      "Cancellation must not apply stale calendar pull data")
        harness.claude.emitComposio([.text("[{\"title\":\"Stale meeting\"}]"), .completed])
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(board.store.tasks.isEmpty)
    }

    func testLateClaudeTaskAICallbackCannotMutateCodexBoard() throws {
        let harness = try CoordinatorProviderHarness()
        defer { harness.removeStore() }

        harness.coordinator.replaceProviderServices(for: .claude)
        harness.coordinator.taskOverlay?.session.decomposeText = "old task"
        harness.coordinator.taskOverlay?.session.runDecompose()
        waitUntil { harness.claude.textRequestCount == 1 }
        harness.coordinator.replaceProviderServices(for: .codex)
        harness.claude.emitText([.text("[{\"title\":\"stale Claude task\"}]"), .completed])
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(harness.coordinator.taskOverlay?.session.decomposePreview.isEmpty == true)
    }

    func testProviderSwitchSettlesStaleMeetingExtractionWithoutAddingTasks() throws {
        let harness = try CoordinatorProviderHarness()
        defer {
            harness.removeStore()
            TranscriptPanelModel.shared.extractTasksHandler = nil
        }
        let notesURL = harness.storeDirectory.appendingPathComponent("meeting.md")
        try "Follow up with the team.".write(to: notesURL, atomically: true, encoding: .utf8)
        let entry = MeetingHistory.Entry(url: notesURL, title: "Meeting",
                                         modified: Date(), snippet: "Follow up")
        var completions: [Int] = []

        harness.coordinator.replaceProviderServices(for: .claude)
        TranscriptPanelModel.shared.extractTasksHandler?(entry) { completions.append($0) }
        waitUntil { harness.claude.textRequestCount == 1 }

        harness.coordinator.replaceProviderServices(for: .codex)
        harness.claude.emitText([.text("[{\"title\":\"stale Claude task\"}]"), .completed])
        waitUntil { completions == [0] }

        XCTAssertTrue(harness.store.tasks.isEmpty)
    }

    func testProviderSwitchSettlesMeetingExtractionWhenCancellationSuppressesCallback() throws {
        let harness = try CoordinatorProviderHarness(suppressClaudeCallbacksOnCancel: true)
        defer {
            harness.removeStore()
            TranscriptPanelModel.shared.extractTasksHandler = nil
        }
        let notesURL = harness.storeDirectory.appendingPathComponent("meeting.md")
        try "Follow up with the team.".write(to: notesURL, atomically: true, encoding: .utf8)
        let entry = MeetingHistory.Entry(url: notesURL, title: "Meeting",
                                         modified: Date(), snippet: "Follow up")
        var completions: [Int] = []

        harness.coordinator.replaceProviderServices(for: .claude)
        TranscriptPanelModel.shared.extractTasksHandler?(entry) { completions.append($0) }
        waitUntil { harness.claude.textRequestCount == 1 }

        harness.coordinator.replaceProviderServices(for: .codex)

        waitUntil { completions == [0] }
        XCTAssertTrue(harness.store.tasks.isEmpty)
    }

    func testProviderServiceRebuildRefreshesModelsForClaudeButNotCodex() throws {
        let harness = try CoordinatorProviderHarness()
        defer { harness.removeStore() }
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-model-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let claudeProbe = try makeModelProbe(in: fixtureDirectory, named: "claude-probe")
        let codexProbe = try makeModelProbe(in: fixtureDirectory, named: "codex-probe")
        let refreshedClaude = HoldingAutomationProvider(kind: .claude,
                                                        version: "claude-refresh-\(UUID().uuidString)",
                                                        binaryPath: claudeProbe.path)
        let untouchedCodex = HoldingAutomationProvider(kind: .codex,
                                                        version: "codex-refresh-\(UUID().uuidString)",
                                                        binaryPath: codexProbe.path)
        let factory = AutomationProviderFactory(
            makeClaude: { _, _ in refreshedClaude },
            makeCodex: { _, _ in untouchedCodex },
            claudeStatus: { .ok(path: claudeProbe.path, version: refreshedClaude.descriptor.version) },
            codexStatus: { .ok(path: codexProbe.path, version: untouchedCodex.descriptor.version) }
        )
        let coordinator = AppCoordinator(
            backendLifecycle: AskBackendLifecycle(), overlay: OverlayController(),
            automationProviderFactory: factory, taskStore: harness.store
        )

        coordinator.replaceProviderServices(for: .claude)
        waitUntil({ ModelCatalog.shared.displayName(for: "sonnet") == "Sonnet 4.5" }, timeout: 2)

        coordinator.replaceProviderServices(for: .codex)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixtureDirectory.appendingPathComponent("codex-probe-ran").path))
    }

    func testSwitchingToCodexCancelsActiveClaudeModelProbeBeforeAnotherAliasLaunches() throws {
        let harness = try CoordinatorProviderHarness()
        defer { harness.removeStore() }
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-model-probe-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let probe = fixtureDirectory.appendingPathComponent("claude-probe")
        let script = #"""
        #!/bin/sh
        fixture_dir="$(dirname "$0")"
        count_file="$fixture_dir/count"
        count=0
        if [ -f "$count_file" ]; then count="$(cat "$count_file")"; fi
        count=$((count + 1))
        printf '%s' "$count" > "$count_file"
        if [ "$count" -gt 1 ]; then : > "$fixture_dir/launched-another-alias"; fi
        trap '' TERM
        printf '%s' "$$" > "$fixture_dir/pid"
        exec /bin/sleep 60
        """#
        try Data(script.utf8).write(to: probe)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: probe.path)
        let provider = HoldingAutomationProvider(kind: .claude,
                                                 version: "claude-cancel-\(UUID().uuidString)",
                                                 binaryPath: probe.path)
        let factory = AutomationProviderFactory(
            makeClaude: { _, _ in provider },
            makeCodex: { _, _ in HoldingAutomationProvider(kind: .codex) },
            claudeStatus: { .ok(path: probe.path, version: provider.descriptor.version) },
            codexStatus: { .ok(path: "/test/codex", version: "test") }
        )
        let coordinator = AppCoordinator(
            backendLifecycle: AskBackendLifecycle(), overlay: OverlayController(),
            automationProviderFactory: factory, taskStore: harness.store
        )

        coordinator.replaceProviderServices(for: .claude)
        let pidURL = fixtureDirectory.appendingPathComponent("pid")
        waitForFile(pidURL)
        let processID = try XCTUnwrap(pid_t(try String(contentsOf: pidURL, encoding: .utf8)))
        defer { Darwin.kill(processID, SIGKILL) }

        coordinator.replaceProviderServices(for: .codex)

        waitForProcessExit(processID, timeout: 1.5)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixtureDirectory.appendingPathComponent("launched-another-alias").path))
    }

    func testUnavailableSelectedProviderKeepsTheLocalBoardAvailable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-unavailable-provider-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskStore(directory: directory)
        let preserved = store.add(TaskItem(title: "Keep this local task"))
        let factory = AutomationProviderFactory(
            makeClaude: { _, _ in HoldingAutomationProvider(kind: .claude) },
            makeCodex: { _, _ in
                XCTFail("Codex must not be built when unavailable")
                return HoldingAutomationProvider(kind: .codex)
            },
            claudeStatus: { .ok(path: "/test/claude", version: "test") },
            codexStatus: { .notFound }
        )
        let coordinator = AppCoordinator(
            backendLifecycle: AskBackendLifecycle(), overlay: OverlayController(),
            automationProviderFactory: factory, taskStore: store
        )

        coordinator.replaceProviderServices(for: .claude)
        coordinator.replaceProviderServices(for: .codex)

        XCTAssertEqual(coordinator.taskOverlay?.session.providerKind, .codex)
        XCTAssertNotNil(coordinator.taskRunner)
        XCTAssertEqual(store.task(preserved.id)?.title, "Keep this local task")
    }

    private func waitUntil(_ condition: @escaping () -> Bool,
                           timeout: TimeInterval = 1) {
        let limit = Date().addingTimeInterval(timeout)
        while !condition(), Date() < limit {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the provider request")
    }

    private func makeModelProbe(in directory: URL, named name: String) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        let script = """
        #!/bin/sh
        : > "$(dirname "$0")/$(basename "$0")-ran"
        printf '{"modelUsage":{"claude-sonnet-4-5-20251001":{}}}'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Timed out waiting for \(url.lastPathComponent)")
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

@MainActor
private final class CoordinatorProviderHarness {
    let claude: HoldingAutomationProvider
    let codex: HoldingAutomationProvider
    let storeDirectory: URL
    let store: TaskStore
    let coordinator: AppCoordinator

    init(suppressClaudeCallbacksOnCancel: Bool = false) throws {
        claude = HoldingAutomationProvider(kind: .claude,
                                           suppressCallbacksOnCancel: suppressClaudeCallbacksOnCancel)
        codex = HoldingAutomationProvider(kind: .codex)
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-provider-generation-\(UUID().uuidString)", isDirectory: true)
        store = TaskStore(directory: storeDirectory)
        let factory = AutomationProviderFactory(
            makeClaude: { [claude] _, _ in claude },
            makeCodex: { [codex] _, _ in codex },
            claudeStatus: { .ok(path: "/test/claude", version: "test") },
            codexStatus: { .ok(path: "/test/codex", version: "test") }
        )
        coordinator = AppCoordinator(
            backendLifecycle: AskBackendLifecycle(),
            overlay: OverlayController(),
            automationProviderFactory: factory,
            taskStore: store
        )
    }

    func removeStore() {
        try? FileManager.default.removeItem(at: storeDirectory)
    }
}

private final class HoldingAutomationProvider: AutomationProvider {
    let descriptor: AutomationProviderDescriptor
    private let lock = NSLock()
    private var textCallbacks: [(AutomationEvent) -> Void] = []
    private var composioCallbacks: [(AutomationEvent) -> Void] = []
    private(set) var cancelAllCount = 0

    var composioRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return composioCallbacks.count
    }

    var textRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return textCallbacks.count
    }

    private let suppressCallbacksOnCancel: Bool

    init(kind: AskBackendKind, version: String = "test", binaryPath: String? = nil,
         suppressCallbacksOnCancel: Bool = false) {
        descriptor = AutomationProviderDescriptor(kind: kind, version: version, binaryPath: binaryPath)
        self.suppressCallbacksOnCancel = suppressCallbacksOnCancel
    }

    func runText(_ request: AutomationRequest,
                 onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        lock.lock()
        textCallbacks.append(onEvent)
        lock.unlock()
        return AutomationCancellation()
    }

    func startRun(_ request: AutomationRunRequest,
                  onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        runText(AutomationRequest(prompt: request.prompt), onEvent: onEvent)
    }

    func runComposio(_ request: ComposioAutomationRequest, token: String,
                     onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        lock.lock()
        composioCallbacks.append(onEvent)
        lock.unlock()
        return AutomationCancellation()
    }

    func cancelAll() {
        lock.lock()
        cancelAllCount += 1
        if suppressCallbacksOnCancel {
            textCallbacks.removeAll()
            composioCallbacks.removeAll()
        }
        lock.unlock()
    }

    func emitComposio(_ events: [AutomationEvent]) {
        lock.lock()
        let callbacks = composioCallbacks
        lock.unlock()
        for event in events {
            callbacks.forEach { $0(event) }
        }
    }

    func emitText(_ events: [AutomationEvent]) {
        lock.lock()
        let callbacks = textCallbacks
        lock.unlock()
        for event in events {
            callbacks.forEach { $0(event) }
        }
    }
}

private final class SummaryAutomationProvider: AutomationProvider {
    let descriptor: AutomationProviderDescriptor
    private(set) var requestedPrompts: [String] = []

    init(kind: AskBackendKind) {
        descriptor = AutomationProviderDescriptor(kind: kind, version: "test")
    }

    func runText(_ request: AutomationRequest,
                 onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        requestedPrompts.append(request.prompt)
        onEvent(.text("## Summary\nDone"))
        onEvent(.completed)
        return AutomationCancellation()
    }

    func startRun(_ request: AutomationRunRequest,
                  onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        runText(AutomationRequest(prompt: request.prompt), onEvent: onEvent)
    }

    func runComposio(_ request: ComposioAutomationRequest, token: String,
                     onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        runText(AutomationRequest(prompt: request.prompt), onEvent: onEvent)
    }

    func cancelAll() {}
}

@MainActor
private final class CoordinatorProviderCoverageHarness {
    let storeDirectory: URL
    let store: TaskStore
    let overlay: OverlayController
    let coordinator: AppCoordinator

    init(launches: ProviderLaunchRecorder) throws {
        let claudeProvider = RecordingAutomationProvider(kind: .claude, recorder: launches)
        let codexProvider = RecordingAutomationProvider(kind: .codex, recorder: launches)
        let claudeAsk = RecordingAskBackend(kind: .claude, recorder: launches)
        let codexAsk = RecordingAskBackend(kind: .codex, recorder: launches)
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-provider-coverage-\(UUID().uuidString)", isDirectory: true)
        store = TaskStore(directory: storeDirectory)
        overlay = OverlayController()
        let automationFactory = AutomationProviderFactory(
            makeClaude: { _, _ in
                launches.record(kind: .claude, role: .automationConstruction)
                return claudeProvider
            },
            makeCodex: { _, _ in
                launches.record(kind: .codex, role: .automationConstruction)
                return codexProvider
            },
            claudeStatus: { .ok(path: "/test/claude", version: "test") },
            codexStatus: { .ok(path: "/test/codex", version: "test") }
        )
        let askBackendFactory = AskBackendFactory(
            makeClaude: { _ in
                launches.record(kind: .claude, role: .askConstruction)
                return claudeAsk
            },
            makeCodex: { _ in
                launches.record(kind: .codex, role: .askConstruction)
                return codexAsk
            },
            claudeStatus: { .ok(path: "/test/claude", version: "test") },
            codexStatus: { .ok(path: "/test/codex", version: "test") }
        )
        coordinator = AppCoordinator(
            backendLifecycle: AskBackendLifecycle(), overlay: overlay,
            automationProviderFactory: automationFactory,
            askBackendFactory: askBackendFactory,
            taskStore: store
        )
    }

    func removeStore() {
        try? FileManager.default.removeItem(at: storeDirectory)
    }
}

private final class ProviderLaunchRecorder {
    enum Role {
        case automationConstruction
        case askConstruction
        case askWarm
        case askTurn
        case automation
    }

    private let lock = NSLock()
    private var launches: [(kind: AskBackendKind, role: Role, context: String)] = []

    func record(kind: AskBackendKind, role: Role, context: String = "") {
        lock.lock()
        launches.append((kind, role, context))
        lock.unlock()
    }

    func count(for kind: AskBackendKind, role: Role? = nil, context: String? = nil) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return launches.filter {
            $0.kind == kind
                && (role == nil || $0.role == role)
                && (context == nil || $0.context == context)
        }.count
    }

    func summary() -> String {
        lock.lock()
        defer { lock.unlock() }
        return launches.map { "\($0.kind.rawValue):\($0.role):\($0.context)" }.joined(separator: ", ")
    }
}

private final class RecordingAskBackend: AskBackend {
    var firstTokenTimeout: TimeInterval = 30

    private let kind: AskBackendKind
    private let recorder: ProviderLaunchRecorder

    init(kind: AskBackendKind, recorder: ProviderLaunchRecorder) {
        self.kind = kind
        self.recorder = recorder
    }

    func startWarm() {
        recorder.record(kind: kind, role: .askWarm)
    }

    func ask(question: String, imagePNG: Data?, onEvent: @escaping (AskBackendEvent) -> Void) {
        recorder.record(kind: kind, role: .askTurn)
        onEvent(.token("Codex answer"))
        onEvent(.completed)
    }

    func shutdown() {}
}

private final class RecordingAutomationProvider: AutomationProvider {
    let descriptor: AutomationProviderDescriptor

    private let recorder: ProviderLaunchRecorder

    init(kind: AskBackendKind, recorder: ProviderLaunchRecorder) {
        descriptor = AutomationProviderDescriptor(kind: kind, version: "test")
        self.recorder = recorder
    }

    func runText(_ request: AutomationRequest,
                 onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        let output: String
        let context: String
        if request.prompt.contains("Decompose the following braindump") {
            output = "[{\"title\":\"Ship provider switch\"}]"
            context = "taskAI"
        } else if request.prompt.contains("suggest 3 short follow-up questions") {
            output = "What changed?\nWhat should I do next?"
            context = "suggestions"
        } else {
            output = "## Summary\nCodex produced the notes."
            context = "meetingSummary"
        }
        recorder.record(kind: descriptor.kind, role: .automation, context: context)
        onEvent(.text(output))
        onEvent(.completed)
        return AutomationCancellation()
    }

    func startRun(_ request: AutomationRunRequest,
                  onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        runText(AutomationRequest(prompt: request.prompt), onEvent: onEvent)
    }

    func runComposio(_ request: ComposioAutomationRequest, token: String,
                     onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        recorder.record(kind: descriptor.kind, role: .automation, context: "composio")
        onEvent(.text("[]"))
        onEvent(.completed)
        return AutomationCancellation()
    }

    func cancelAll() {}
}
