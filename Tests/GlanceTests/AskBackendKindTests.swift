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
}
