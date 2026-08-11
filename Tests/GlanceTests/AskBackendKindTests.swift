import XCTest
@testable import Glance

final class AskBackendKindTests: XCTestCase {
    func testDefaultsToClaudeAndDecodesCodex() {
        XCTAssertEqual(AskBackendKind.defaultValue, .claude)
        XCTAssertEqual(AskBackendKind(rawValue: "codex"), .codex)
    }

    func testCodexUsesCLIDisplayName() {
        XCTAssertEqual(AskBackendKind.codex.displayName, "Codex CLI")
    }

    @MainActor
    func testTaskSettingsExposeAskBackendControl() {
        XCTAssertEqual(TaskSettingsView.askBackendRowTitle, "Ask backend")
    }

    @MainActor
    func testCodexModelPresentationKeepsStoredClaudeAliasOutOfTheMenu() {
        let storedModel = "sonnet"

        XCTAssertEqual(ModelCatalog.choices(for: .codex), [.automatic])
        XCTAssertEqual(ModelCatalog.presentedChoice(for: storedModel, provider: .codex),
                       .automatic)
        XCTAssertEqual(ModelCatalog.storedModel(afterSelecting: .automatic,
                                                current: storedModel,
                                                provider: .codex),
                       "sonnet")
    }
}
