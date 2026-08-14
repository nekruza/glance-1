import XCTest
@testable import Glance

@MainActor
final class ProviderGenerationTests: XCTestCase {
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
}

@MainActor
private final class CoordinatorProviderHarness {
    let claude = HoldingAutomationProvider(kind: .claude)
    let codex = HoldingAutomationProvider(kind: .codex)
    let storeDirectory: URL
    let store: TaskStore
    let coordinator: AppCoordinator

    init() throws {
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

    init(kind: AskBackendKind) {
        descriptor = AutomationProviderDescriptor(kind: kind, version: "test")
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
