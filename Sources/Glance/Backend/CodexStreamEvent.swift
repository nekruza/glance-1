import Foundation

/// The subset of `codex exec --json` events used by the ask overlay.
enum CodexStreamEvent: Equatable {
    case threadStarted(String)
    case token(String)
    case completed
    case failed(String)
    case ignored

    var automationEvent: AutomationEvent? {
        switch self {
        case .threadStarted(let id):
            return .sessionID(id)
        case .token(let text):
            return .text(text)
        case .completed:
            return .completed
        case .failed(let message):
            return .failed(message)
        case .ignored:
            return nil
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed:
            return true
        case .threadStarted, .token, .ignored:
            return false
        }
    }

    static func decode(_ line: String) throws -> CodexStreamEvent {
        let data = Data(line.utf8)
        let payload = try JSONDecoder().decode(Payload.self, from: data)

        switch payload.type {
        case "thread.started":
            guard let threadID = payload.threadID else { return .ignored }
            return .threadStarted(threadID)
        case "item.completed":
            if payload.item?.type == "agent_message", let text = payload.item?.text {
                return .token(text)
            }
            return .ignored
        case "turn.completed":
            return .completed
        case "turn.failed":
            return .failed(payload.error?.message ?? "Codex turn failed.")
        case "error":
            return .failed(payload.message ?? payload.error?.message ?? "Codex returned an error.")
        default:
            return .ignored
        }
    }
}

private extension CodexStreamEvent {
    struct Payload: Decodable {
        let type: String
        let threadID: String?
        let item: Item?
        let error: Failure?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case type
            case threadID = "thread_id"
            case item
            case error
            case message
        }
    }

    struct Item: Decodable {
        let type: String
        let text: String?
        let message: String?
    }

    struct Failure: Decodable {
        let message: String?
    }
}
