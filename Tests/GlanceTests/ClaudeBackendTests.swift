import XCTest
@testable import Glance

extension AskBackendEvent: Equatable {
    public static func == (lhs: AskBackendEvent, rhs: AskBackendEvent) -> Bool {
        switch (lhs, rhs) {
        case let (.token(lhsText), .token(rhsText)):
            return lhsText == rhsText
        case (.completed, .completed):
            return true
        case let (.failed(lhsMessage), .failed(rhsMessage)):
            return lhsMessage == rhsMessage
        default:
            return false
        }
    }
}

final class ClaudeBackendTests: XCTestCase {
    func testMapsTextDeltaToTokenEvent() throws {
        let fixture = #"""
        {
          "type": "stream_event",
          "event": {
            "type": "content_block_delta",
            "delta": { "type": "text_delta", "text": "hello" }
          }
        }
        """#.data(using: .utf8)!

        let line = try JSONDecoder().decode(StreamLine.self, from: fixture)
        XCTAssertEqual(line.askBackendEvent, .token("hello"))
    }
}
