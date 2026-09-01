import XCTest
@testable import Glance

/// The renderer previously printed unhandled Markdown syntax verbatim — a `>`
/// blockquote and a `---` rule both reached the user as literal characters.
/// These lock the block parse down.
final class MarkdownTextTests: XCTestCase {

    /// Compact, order-preserving description of the parse, so assertions read
    /// as the shape of the rendered output.
    private func shape(_ md: String) -> [String] {
        MarkdownText.parse(md).map { block in
            switch block {
            case .heading(let level, let text):        return "h\(level):\(text)"
            case .bullet(let depth, let checked, let text):
                let box = checked.map { $0 ? "[x]" : "[ ]" } ?? ""
                return "ul\(depth)\(box):\(text)"
            case .ordered(let depth, let number, let text): return "ol\(depth):\(number):\(text)"
            case .code(let code):                      return "code:\(code)"
            case .quote(let text):                     return "quote:\(text)"
            case .paragraph(let text):                 return "p:\(text)"
            case .rule:                                return "rule"
            }
        }
    }

    // MARK: - Syntax that used to leak through as literal characters

    func testBlockquoteStripsTheMarker() {
        XCTAssertEqual(shape("> \"needs a Kato change\""), ["quote:\"needs a Kato change\""])
    }

    func testBlockquoteWithoutSpaceAfterMarker() {
        XCTAssertEqual(shape(">quoted"), ["quote:quoted"])
    }

    func testNestedBlockquoteMarkersAreAllStripped() {
        XCTAssertEqual(shape("> > deeply quoted"), ["quote:deeply quoted"])
    }

    func testConsecutiveQuoteLinesFormOneQuote() {
        XCTAssertEqual(shape("> first\n> second"), ["quote:first second"])
    }

    func testBlankQuoteLineSplitsTwoQuotes() {
        XCTAssertEqual(shape("> a\n\n> b"), ["quote:a", "quote:b"])
    }

    func testThematicBreaks() {
        XCTAssertEqual(shape("---"), ["rule"])
        XCTAssertEqual(shape("***"), ["rule"])
        XCTAssertEqual(shape("___"), ["rule"])
        XCTAssertEqual(shape("- - -"), ["rule"])
    }

    func testTwoDashesIsNotARule() {
        XCTAssertEqual(shape("--"), ["p:--"])
    }

    func testDashBulletIsNotMistakenForARule() {
        XCTAssertEqual(shape("- an item"), ["ul0:an item"])
    }

    func testBoldRunIsNotMistakenForARule() {
        XCTAssertEqual(shape("***emphatic***"), ["p:***emphatic***"])
    }

    // MARK: - Paragraph flow

    func testSoftWrappedLinesJoinIntoOneParagraph() {
        XCTAssertEqual(
            shape("Anyone can read a wristband.\nOnly the gate can make one."),
            ["p:Anyone can read a wristband. Only the gate can make one."])
    }

    func testBlankLineSeparatesParagraphs() {
        XCTAssertEqual(shape("first\n\nsecond"), ["p:first", "p:second"])
    }

    func testHeadingInterruptsParagraph() {
        XCTAssertEqual(shape("intro\n## Section\nbody"),
                       ["p:intro", "h2:Section", "p:body"])
    }

    // MARK: - Lists

    func testNestedBulletsTrackDepth() {
        XCTAssertEqual(shape("- a\n  - b\n    - c\n- d"),
                       ["ul0:a", "ul1:b", "ul2:c", "ul0:d"])
    }

    func testFourSpaceIndentNestsOneLevelNotTwo() {
        XCTAssertEqual(shape("- a\n    - b"), ["ul0:a", "ul1:b"])
    }

    func testNestingDepthIsClamped() {
        let deep = (0..<8).map { String(repeating: " ", count: $0 * 2) + "- x" }.joined(separator: "\n")
        let depths = MarkdownText.parse(deep).compactMap { block -> Int? in
            if case .bullet(let depth, _, _) = block { return depth }
            return nil
        }
        XCTAssertEqual(depths, [0, 1, 2, 3, 3, 3, 3, 3])
    }

    func testTaskListCheckboxes() {
        XCTAssertEqual(shape("- [ ] todo\n- [x] done\n- [X] also done"),
                       ["ul0[ ]:todo", "ul0[x]:done", "ul0[x]:also done"])
    }

    func testAsteriskAndPlusBullets() {
        XCTAssertEqual(shape("* star\n+ plus"), ["ul0:star", "ul0:plus"])
    }

    func testOrderedListAcceptsDotAndParen() {
        XCTAssertEqual(shape("1. first\n2) second"), ["ol0:1:first", "ol0:2:second"])
    }

    func testDecimalNumberIsNotAnOrderedItem() {
        XCTAssertEqual(shape("3.14 is pi"), ["p:3.14 is pi"])
    }

    func testListResetsNestingAfterAParagraph() {
        XCTAssertEqual(shape("  - deep\n\nbetween\n\n  - deep again"),
                       ["ul0:deep", "p:between", "ul0:deep again"])
    }

    // MARK: - Code fences (streaming)

    func testFencedCodeKeepsIndentationAndNewlines() {
        XCTAssertEqual(shape("```swift\nlet x = 1\n    let y = 2\n```"),
                       ["code:let x = 1\n    let y = 2"])
    }

    func testUnclosedFenceStillRendersAsCode() {
        XCTAssertEqual(shape("intro\n\n```\npartial stream"),
                       ["p:intro", "code:partial stream"])
    }

    func testMarkdownSyntaxInsideAFenceIsNotParsed() {
        XCTAssertEqual(shape("```\n> not a quote\n---\n- not a bullet\n```"),
                       ["code:> not a quote\n---\n- not a bullet"])
    }

    // MARK: - Vertical rhythm

    func testSiblingListItemsHugAndHeadingsGetAir() {
        let items = MarkdownText.parse("- a\n- b")
        XCTAssertEqual(MarkdownText.gap(from: items[0], to: items[1]), 5)

        let heading = MarkdownText.parse("intro\n## Section")
        XCTAssertEqual(MarkdownText.gap(from: heading[0], to: heading[1]), 20)
    }

    func testFirstBlockHasNoLeadingGap() {
        let blocks = MarkdownText.parse("## Section")
        XCTAssertEqual(MarkdownText.gap(from: nil, to: blocks[0]), 0)
    }

    // MARK: - Regression: the exact content from the reported screenshot

    func testReportedScreenshotContentHasNoLiteralSyntaxLeft() {
        let md = """
        ## What your sentence means

        > "This needs a Kato change minting the JWT for agency hosts"

        In plain words:

        ---

        **One line to remember:**
        """
        let blocks = shape(md)
        XCTAssertEqual(blocks, [
            "h2:What your sentence means",
            "quote:\"This needs a Kato change minting the JWT for agency hosts\"",
            "p:In plain words:",
            "rule",
            "p:**One line to remember:**",
        ])
        XCTAssertFalse(blocks.contains { $0.hasPrefix("p:>") || $0 == "p:---" },
                       "Markdown syntax reached the user as literal text")
    }
}
