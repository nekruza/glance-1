import XCTest
@testable import Glance

/// The footer Effort menu offers only what the provider and chosen model can
/// actually apply, and passes the pick through exactly once.
@MainActor
final class EffortLevelTests: XCTestCase {

    func testClaudeLevelsFollowTheModelsSupportedList() {
        let model = ModelOption(value: "opus", supportsEffort: true,
                                supportedEffortLevels: ["low", "medium", "high"])
        XCTAssertEqual(EffortLevel.available(for: .claude, model: model), [.low, .medium, .high])
    }

    func testClaudeMaxIsNeverOffered() {
        // `max` is ignored by the CLI on a live session, so it must not appear.
        let model = ModelOption(value: "opus", supportsEffort: true,
                                supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(EffortLevel.available(for: .claude, model: model), [.low, .medium, .high, .xhigh])
    }

    func testModelThatDoesNotSupportEffortOffersNone() {
        let model = ModelOption(value: "haiku", supportsEffort: false)
        XCTAssertEqual(EffortLevel.available(for: .claude, model: model), [])
    }

    func testModelThatDoesNotReportEffortOffersEveryLevel() {
        XCTAssertEqual(EffortLevel.available(for: .claude, model: ModelOption(value: "opus")),
                       EffortLevel.allCases)
    }

    func testCodexOffersLowMediumHigh() {
        XCTAssertEqual(EffortLevel.available(for: .codex, model: nil), [.low, .medium, .high])
    }

    func testModelCatalogDecodesEffortCapabilities() throws {
        let json = """
        {"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)",
         "description":"Opus 5.5","supportsEffort":true,
         "supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true}
        """
        let option = try JSONDecoder().decode(ModelOption.self, from: Data(json.utf8))
        XCTAssertEqual(option.supportsEffort, true)
        XCTAssertEqual(option.supportedEffortLevels, ["low", "medium", "high", "xhigh", "max"])
    }

    func testSessionHidesTheMenuUntilTheClaudeModelListArrives() {
        let session = OverlaySession()
        session.backendKind = .claude
        XCTAssertEqual(session.effortLevels, [])
        session.modelOptions = [ModelOption(value: "default", supportsEffort: true,
                                            supportedEffortLevels: ["low", "high"])]
        XCTAssertEqual(session.effortLevels, [.low, .high])
    }

    func testSelectingEffortNotifiesTheHandlerOncePerChange() {
        let session = OverlaySession()
        var received: [EffortLevel?] = []
        session.effortHandler = { received.append($0) }
        session.selectEffort(.high)
        session.selectEffort(.high)   // no change, no call
        session.selectEffort(nil)     // back to the CLI default
        XCTAssertEqual(received, [.high, nil])
    }
}
