import XCTest
@testable import Glance

final class CodexLocatorTests: XCTestCase {
    func testMissingCodexBinaryHasInstallationMessage() {
        XCTAssertEqual(BackendTester.message(for: .codex, status: .notFound),
                       "Codex CLI not found. Install it and run `codex` to sign in.")
    }
}
