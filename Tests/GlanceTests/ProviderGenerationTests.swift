import XCTest
@testable import Glance

@MainActor
final class ProviderGenerationTests: XCTestCase {
    func testCodexSelectionHasNoClaudeAutomationLaunches() {
        let services = ProviderCoverageServiceBundle(kind: .codex)
        let previousKey = Preferences.shared.composioKey
        let previousURL = Preferences.shared.composioURL
        Preferences.shared.composioKey = "test-composio-token"
        Preferences.shared.composioURL = "https://connect.composio.dev/mcp"
        defer {
            Preferences.shared.composioKey = previousKey
            Preferences.shared.composioURL = previousURL
        }

        let workFinished = expectation(description: "selected provider completes every service request")
        services.exerciseAskOneShotTaskAISuggestionsComposioAndMeetingSummary {
            workFinished.fulfill()
        }
        wait(for: [workFinished], timeout: 1)

        XCTAssertEqual(services.claudeLaunchCount, 0,
                       "Codex selection must not launch Claude for any AI service")
        XCTAssertEqual(services.codexAskLaunchCount, 1)
        XCTAssertEqual(services.codexAutomationLaunchCount, 4,
                       "Task AI, suggestions, Composio, and meeting summary use Codex")
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

/// Exercises the same selected-provider service shape used by the app without
/// launching either real CLI. Every fake launch is recorded by provider kind,
/// so this regression fails if any one-shot service quietly reintroduces a
/// Claude-specific construction path while Codex is selected.
@MainActor
private final class ProviderCoverageServiceBundle {
    private let launches = ProviderLaunchRecorder()
    private let claudeProvider: RecordingAutomationProvider
    private let codexProvider: RecordingAutomationProvider
    private let claudeAskBackend: RecordingAskBackend
    private let codexAskBackend: RecordingAskBackend
    private let askBackend: RecordingAskBackend
    private let taskAI: TaskAI
    private let suggestions: SuggestionService
    private let composio: ComposioIngest
    private let transcriber = MeetingTranscriber()

    init(kind: AskBackendKind) {
        claudeProvider = RecordingAutomationProvider(kind: .claude, recorder: launches)
        codexProvider = RecordingAutomationProvider(kind: .codex, recorder: launches)
        claudeAskBackend = RecordingAskBackend(kind: .claude, recorder: launches)
        codexAskBackend = RecordingAskBackend(kind: .codex, recorder: launches)
        let selectedProvider = kind == .claude ? claudeProvider : codexProvider
        askBackend = kind == .claude ? claudeAskBackend : codexAskBackend
        taskAI = TaskAI(provider: selectedProvider)
        suggestions = SuggestionService(provider: selectedProvider)
        composio = ComposioIngest(provider: selectedProvider)
        transcriber.summaryProvider = { selectedProvider }
    }

    var claudeLaunchCount: Int { launches.count(for: .claude) }
    var codexAskLaunchCount: Int { launches.count(for: .codex, role: .ask) }
    var codexAutomationLaunchCount: Int { launches.count(for: .codex, role: .automation) }

    func exerciseAskOneShotTaskAISuggestionsComposioAndMeetingSummary(
        completion: @escaping () -> Void
    ) {
        let settled = DispatchGroup()
        for _ in 0..<4 { settled.enter() }

        askBackend.startWarm()
        askBackend.ask(question: "What is on screen?", imagePNG: nil) { event in
            if case .completed = event { settled.leave() }
        }
        taskAI.decompose(prompt: "Ship the provider switch") { _ in
            settled.leave()
        }
        suggestions.suggest(question: "What is on screen?", answer: "A board") { _ in
            settled.leave()
        }
        composio.listConnections { _, _ in
            settled.leave()
        }
        transcriber.summarizeForTesting("Discussed the selected provider.")

        settled.notify(queue: .main, execute: completion)
    }
}

private final class ProviderLaunchRecorder {
    enum Role {
        case ask
        case automation
    }

    private let lock = NSLock()
    private var launches: [(kind: AskBackendKind, role: Role)] = []

    func record(kind: AskBackendKind, role: Role) {
        lock.lock()
        launches.append((kind, role))
        lock.unlock()
    }

    func count(for kind: AskBackendKind, role: Role? = nil) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return launches.filter { $0.kind == kind && (role == nil || $0.role == role) }.count
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

    func startWarm() {}

    func ask(question: String, imagePNG: Data?, onEvent: @escaping (AskBackendEvent) -> Void) {
        recorder.record(kind: kind, role: .ask)
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
        recorder.record(kind: descriptor.kind, role: .automation)
        let output: String
        if request.prompt.contains("Decompose the following braindump") {
            output = "[{\"title\":\"Ship provider switch\"}]"
        } else if request.prompt.contains("suggest 3 short follow-up questions") {
            output = "What changed?\nWhat should I do next?"
        } else {
            output = "## Summary\nCodex produced the notes."
        }
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
        recorder.record(kind: descriptor.kind, role: .automation)
        onEvent(.text("[]"))
        onEvent(.completed)
        return AutomationCancellation()
    }

    func cancelAll() {}
}
