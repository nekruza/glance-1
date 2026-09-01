import XCTest
import AppKit
@testable import Glance

/// Copying a draft must paste as formatted text into Slack/Mail (RTF) and as
/// clean words into plain editors — never as literal **markdown** syntax.
final class DraftCopyTests: XCTestCase {

    private let sample = "Hi **team** — see [the doc](https://example.com/x)!"

    func testPlainTextStripsMarkdownSyntax() {
        let rich = DraftCopy.attributedString(for: sample)
        XCTAssertEqual(rich.string, "Hi team — see the doc!")
    }

    func testBoldIntentResolvesToABoldFont() {
        let rich = DraftCopy.attributedString(for: sample)
        let range = (rich.string as NSString).range(of: "team")
        let font = rich.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(NSFontManager.shared.traits(of: font!).contains(.boldFontMask),
                      "bold presentation intent must become a real bold font, or RTF drops it")
    }

    func testLinkSurvives() {
        let rich = DraftCopy.attributedString(for: sample)
        let range = (rich.string as NSString).range(of: "the doc")
        let link = rich.attribute(.link, at: range.location, effectiveRange: nil)
        XCTAssertNotNil(link)
    }

    func testWritePutsBothRepresentationsOnThePasteboard() {
        let pb = NSPasteboard(name: NSPasteboard.Name("glance-test-draft-copy"))
        DraftCopy.write(sample, to: pb)
        XCTAssertEqual(pb.string(forType: .string), "Hi team — see the doc!")
        let rtf = pb.data(forType: .rtf)
        XCTAssertNotNil(rtf, "rich representation missing")
        let roundTrip = NSAttributedString(rtf: rtf!, documentAttributes: nil)
        XCTAssertEqual(roundTrip?.string, "Hi team — see the doc!")
    }

    func testParagraphBreaksArePreserved() {
        let rich = DraftCopy.attributedString(for: "First.\n\nSecond.")
        XCTAssertEqual(rich.string, "First.\n\nSecond.")
    }
}
