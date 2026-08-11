import XCTest
@testable import Glance

final class AutomationProviderTests: XCTestCase {
    func testCodexDescriptorUsesCodexNameAndDefaultModelOnly() {
        let descriptor = AutomationProviderDescriptor(kind: .codex, version: "0.147.0")
        XCTAssertEqual(descriptor.displayName, "Codex CLI")
        XCTAssertEqual(descriptor.modelChoices, [.automatic])
    }

    func testFactoryReportsTheSelectedMissingCLI() {
        XCTAssertEqual(
            AutomationProviderFactory.unavailableMessage(kind: .codex, status: .notFound),
            "Codex CLI not found. Install it and run `codex` to sign in."
        )
    }

    func testDescriptorMapsOnlySupportedNamedModels() {
        let descriptor = AutomationProviderDescriptor(kind: .codex, version: "0.147.0")

        XCTAssertNil(descriptor.model(for: .automatic))
        XCTAssertNil(descriptor.model(for: .sonnet))
    }

    func testCancellationRunsItsActionOnlyOnce() {
        var cancelCount = 0
        let cancellation = AutomationCancellation { cancelCount += 1 }

        cancellation.cancel()
        cancellation.cancel()

        XCTAssertEqual(cancelCount, 1)
    }

    func testFactoryBuildsOnlyTheSelectedProvider() {
        var claudeBuildCount = 0
        var codexBuildCount = 0
        let factory = AutomationProviderFactory(
            makeClaude: { _, _ in
                claudeBuildCount += 1
                return AutomationProviderSpy(kind: .claude)
            },
            makeCodex: { _, _ in
                codexBuildCount += 1
                return AutomationProviderSpy(kind: .codex)
            },
            claudeStatus: { .ok(path: "/fake/claude", version: "2.0") },
            codexStatus: { .ok(path: "/fake/codex", version: "0.147.0") }
        )

        let result = factory.make(kind: .codex)

        guard case .success(let provider) = result else {
            return XCTFail("Expected the available selected provider")
        }
        XCTAssertEqual(provider.descriptor.kind, .codex)
        XCTAssertEqual(claudeBuildCount, 0)
        XCTAssertEqual(codexBuildCount, 1)
    }
}

final class AutomationProviderSpy: AutomationProvider {
    let descriptor: AutomationProviderDescriptor
    private(set) var requests: [AutomationRequest] = []
    private(set) var cancelAllCount = 0
    var finalText: String

    init(kind: AskBackendKind, finalText: String = "") {
        descriptor = AutomationProviderDescriptor(kind: kind, version: "test")
        self.finalText = finalText
    }

    func runText(_ request: AutomationRequest,
                 onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        requests.append(request)
        if !finalText.isEmpty { onEvent(.text(finalText)) }
        onEvent(.completed)
        return AutomationCancellation()
    }

    func startRun(_ request: AutomationRunRequest,
                  onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        runText(AutomationRequest(prompt: request.prompt, model: request.model), onEvent: onEvent)
    }

    func runComposio(_ request: ComposioAutomationRequest, token: String,
                     onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        runText(AutomationRequest(prompt: request.prompt), onEvent: onEvent)
    }

    func cancelAll() { cancelAllCount += 1 }
}
