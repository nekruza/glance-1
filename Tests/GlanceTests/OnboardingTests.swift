import XCTest
@testable import Glance

final class OnboardingTests: XCTestCase {

    private var pages: [OnboardingPage] {
        OnboardingCatalog.pages(askHotkey: "⌥Space", taskHotkey: "⌥T")
    }

    private var allCopy: String {
        pages.map { page in
            ([page.title, page.subtitle] + page.rows.flatMap { [$0.title, $0.detail] })
                .joined(separator: " ")
        }.joined(separator: " ").lowercased()
    }

    // The task's hard cap — and the tour's shape.
    func testExactlyFivePages() {
        XCTAssertEqual(pages.count, 5)
    }

    func testPageIDsAreStable() {
        XCTAssertEqual(pages.map(\.id), ["welcome", "ask", "provider", "tasks", "privacy"])
    }

    func testEveryPageHasSubstantiveContent() {
        for page in pages {
            XCTAssertFalse(page.title.isEmpty, "\(page.id) title empty")
            XCTAssertFalse(page.subtitle.isEmpty, "\(page.id) subtitle empty")
            XCTAssertFalse(page.symbol.isEmpty, "\(page.id) symbol empty")
            XCTAssertGreaterThanOrEqual(page.rows.count, 3, "\(page.id) needs ≥3 rows")
            for row in page.rows {
                XCTAssertFalse(row.title.isEmpty, "\(page.id) row title empty")
                XCTAssertFalse(row.detail.isEmpty, "\(page.id) row detail empty")
                XCTAssertFalse(row.symbol.isEmpty, "\(page.id) row symbol empty")
            }
        }
    }

    func testInjectedHotkeysAppearInCopy() {
        let copy = pages.map(\.subtitle).joined(separator: " ")
        XCTAssertTrue(copy.contains("⌥Space"))
        XCTAssertTrue(copy.contains("⌥T"))
    }

    // The tour must mention every key surface of the app.
    func testCopyCoversKeyFunctionality() {
        let required = [
            "menu bar",          // where the app lives
            "screen",            // screen-aware asking
            "overlay",           // the ask surface
            "claude code",       // provider choice
            "codex",             // provider choice
            "settings",          // where configuration happens
            "task board",        // V2 task system
            "jira", "slack", "gmail", "composio", // integrations
            "briefing",          // morning briefing
            "screen recording",  // TCC permission
            "approval",          // human-in-the-loop sending
            "network",           // privacy posture
        ]
        for term in required {
            XCTAssertTrue(allCopy.contains(term), "onboarding copy never mentions \"\(term)\"")
        }
    }

    @MainActor
    func testCompletionFlagGatesFirstLaunchPresentation() {
        let prefs = Preferences.shared
        let original = prefs.onboardingCompleted
        defer { prefs.onboardingCompleted = original }

        prefs.onboardingCompleted = false
        XCTAssertTrue(OnboardingWindowController.shouldShow)

        prefs.onboardingCompleted = true
        XCTAssertFalse(OnboardingWindowController.shouldShow)
    }

    func testCompletionFlagRoundTripsThroughDefaults() {
        let prefs = Preferences.shared
        let original = prefs.onboardingCompleted
        defer { prefs.onboardingCompleted = original }

        prefs.onboardingCompleted = true
        XCTAssertTrue(prefs.onboardingCompleted)
        prefs.onboardingCompleted = false
        XCTAssertFalse(prefs.onboardingCompleted)
    }
}
