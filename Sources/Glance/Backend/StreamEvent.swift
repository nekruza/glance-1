import Foundation

/// Minimal decoder for the subset of `--output-format stream-json` NDJSON we act
/// on. The stream is rich; we only need token deltas, the session id, and the
/// terminal result. Unknown fields are ignored.
struct StreamLine: Decodable {
    let type: String
    let sessionId: String?
    let subtype: String?
    let isError: Bool?
    let result: String?
    let event: Inner?

    struct Inner: Decodable {
        let type: String?
        let delta: Delta?
        struct Delta: Decodable {
            let type: String?
            let text: String?
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case subtype
        case isError = "is_error"
        case result
        case event
    }

    /// The incremental assistant text carried by this line, if any.
    /// `stream_event → content_block_delta → text_delta.text` (FR11 streaming).
    var streamedText: String? {
        guard type == "stream_event",
              event?.type == "content_block_delta",
              event?.delta?.type == "text_delta" else { return nil }
        return event?.delta?.text
    }

    var isResult: Bool { type == "result" }
}
