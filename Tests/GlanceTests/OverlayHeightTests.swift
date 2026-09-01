import XCTest
import SwiftUI
@testable import Glance

/// Regression tests for the idle-height feedback loop: the panel is sized from
/// `session.contentHeight`, so that measurement must reflect the content's IDEAL
/// height and never the (already shrunk) window height it was proposed.
/// Without `.fixedSize(vertical:)` on the idle column, SwiftUI compressed the
/// growing TextField into the short window and reported the window height back —
/// so rows past the first stayed clipped forever.
final class OverlayHeightTests: XCTestCase {

    /// Hosts OverlayView in a deliberately-too-short window, like the real
    /// panel after it has shrunk to the one-row idle height, and returns the
    /// height the view reports for the given input.
    @MainActor
    private func measuredHeight(input: String, windowHeight: CGFloat) -> CGFloat {
        let session = OverlaySession()
        session.input = input
        let host = NSHostingView(rootView: OverlayView(session: session))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(x: 0, y: 0, width: Theme.overlayWidth, height: windowHeight)

        // A real window: SwiftUI skips layout for a view with no window.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // GeometryReader's onAppear/onChange land on the next runloop turns.
        for _ in 0..<8 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
        }
        return session.contentHeight
    }

    /// The bug: with the window already collapsed to one row, typing more rows
    /// must still report a taller content height (otherwise nothing can grow).
    @MainActor
    func testIdleContentHeightGrowsWithInputRowsDespiteShortWindow() {
        let oneRow = measuredHeight(input: "one", windowHeight: 96)
        let fourRows = measuredHeight(input: "one\ntwo\nthree\nfour", windowHeight: 96)

        XCTAssertGreaterThan(oneRow, 20, "baseline idle height should be measured at all")
        XCTAssertGreaterThan(fourRows, oneRow + 20,
                             "four rows (\(fourRows)) must measure taller than one row (\(oneRow)); "
                             + "equal heights mean the measurement is echoing the window height")
    }

    /// The measurement must be a function of the content only — the same text in
    /// a taller or shorter window must report the same height, or the controller's
    /// resize would oscillate instead of settling in one step.
    @MainActor
    func testIdleContentHeightIsIndependentOfWindowHeight() {
        let inShortWindow = measuredHeight(input: "one\ntwo\nthree", windowHeight: 60)
        let inTallWindow = measuredHeight(input: "one\ntwo\nthree", windowHeight: 400)

        XCTAssertEqual(inShortWindow, inTallWindow, accuracy: 1,
                       "idle height must not depend on the window it is measured in")
    }

    /// Each extra row adds height monotonically, up to the 6-row lineLimit.
    @MainActor
    func testIdleContentHeightIsMonotonicInRowCount() {
        var previous: CGFloat = 0
        for rows in 1...5 {
            let text = (1...rows).map(String.init).joined(separator: "\n")
            let height = measuredHeight(input: text, windowHeight: 96)
            XCTAssertGreaterThan(height, previous,
                                 "row \(rows) height \(height) should exceed row \(rows - 1) height \(previous)")
            previous = height
        }
    }
}
