import XCTest
@testable import Glance

final class OverlaySizingTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let name = "glance-sizing-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDefaultsMatchTheDesignedSize() {
        let sizing = OverlaySizing(defaults: freshDefaults())
        XCTAssertEqual(sizing.contentSize(isConversation: false, idleHeight: 96), NSSize(width: 640, height: 96))
        XCTAssertEqual(sizing.contentSize(isConversation: true, idleHeight: 96), NSSize(width: 640, height: 560))
    }

    func testConversationResizeKeepsWidthAndHeight() {
        var sizing = OverlaySizing(defaults: freshDefaults())
        sizing.recordUserResize(NSSize(width: 900, height: 720), isConversation: true)
        XCTAssertEqual(sizing.contentSize(isConversation: true, idleHeight: 96), NSSize(width: 900, height: 720))
        // Idle keeps its content height but adopts the dragged width.
        XCTAssertEqual(sizing.contentSize(isConversation: false, idleHeight: 110), NSSize(width: 900, height: 110))
    }

    func testIdleResizeOnlyChangesWidth() {
        var sizing = OverlaySizing(defaults: freshDefaults())
        sizing.recordUserResize(NSSize(width: 700, height: 300), isConversation: false)
        XCTAssertEqual(sizing.contentSize(isConversation: true, idleHeight: 96), NSSize(width: 700, height: 560))
    }

    func testResizeIsClampedToMinimums() {
        var sizing = OverlaySizing(defaults: freshDefaults())
        sizing.recordUserResize(NSSize(width: 100, height: 50), isConversation: true)
        let size = sizing.contentSize(isConversation: true, idleHeight: 96)
        XCTAssertEqual(size.width, OverlaySizing.minWidth)
        XCTAssertEqual(size.height, OverlaySizing.minConversationHeight)
    }

    func testDraggedSizeSurvivesRelaunch() {
        let defaults = freshDefaults()
        var first = OverlaySizing(defaults: defaults)
        first.recordUserResize(NSSize(width: 820, height: 650), isConversation: true)
        let second = OverlaySizing(defaults: defaults)
        XCTAssertEqual(second.contentSize(isConversation: true, idleHeight: 96), NSSize(width: 820, height: 650))
    }
}
