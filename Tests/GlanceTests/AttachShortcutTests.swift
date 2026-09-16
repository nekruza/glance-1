import XCTest
import AppKit
@testable import Glance

/// ⌘J toggles "attach a screenshot to the next message" from the keyboard so
/// the footer photo button never needs the mouse.
final class AttachShortcutTests: XCTestCase {

    @MainActor
    func testCommandJMatchesShortcut() {
        XCTAssertTrue(OverlayPanel.isAttachShortcut(characters: "j", modifiers: [.command]))
    }

    @MainActor
    func testShortcutIsCaseInsensitive() {
        // Caps Lock (or a stuck shift on some layouts) reports "J".
        XCTAssertTrue(OverlayPanel.isAttachShortcut(characters: "J", modifiers: [.command, .capsLock]))
    }

    @MainActor
    func testOtherCombosDoNotMatch() {
        XCTAssertFalse(OverlayPanel.isAttachShortcut(characters: "j", modifiers: []))
        XCTAssertFalse(OverlayPanel.isAttachShortcut(characters: "j", modifiers: [.command, .shift]))
        XCTAssertFalse(OverlayPanel.isAttachShortcut(characters: "j", modifiers: [.command, .option]))
        XCTAssertFalse(OverlayPanel.isAttachShortcut(characters: "k", modifiers: [.command]))
        XCTAssertFalse(OverlayPanel.isAttachShortcut(characters: nil, modifiers: [.command]))
    }

    // Note: no test builds an OverlayPanel or an OverlayController. A real
    // NSPanel spins AppKit's window machinery here and makes the (already
    // timing-sensitive) CodexStreamEventTests shutdown expectation fail. The
    // monitor-to-panel wiring is verified live against the running app
    // instead (Scripts/build-app.sh + injected key events).

    @MainActor
    func testSessionToggleFlipsAttachImage() {
        let session = OverlaySession()
        XCTAssertFalse(session.attachImage)

        session.toggleAttachImage()
        XCTAssertTrue(session.attachImage)

        session.toggleAttachImage()
        XCTAssertFalse(session.attachImage)
    }

    private static func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown,
                         location: .zero,
                         modifierFlags: modifiers,
                         timestamp: 0,
                         windowNumber: 0,
                         context: nil,
                         characters: characters,
                         charactersIgnoringModifiers: characters,
                         isARepeat: false,
                         keyCode: 0)!
    }
}
