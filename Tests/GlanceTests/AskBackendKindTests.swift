import XCTest
@testable import Glance

final class AskBackendKindTests: XCTestCase {
    func testDefaultsToClaudeAndDecodesCodex() {
        XCTAssertEqual(AskBackendKind.defaultValue, .claude)
        XCTAssertEqual(AskBackendKind(rawValue: "codex"), .codex)
    }
}
