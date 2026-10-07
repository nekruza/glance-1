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
    let model: String?
    let event: Inner?
    /// `system/commands_changed` carries the refreshed command list here.
    let commands: LenientArray<SlashCommand>?
    /// `system/init`: commands only the interactive terminal UI can run.
    let terminalSlashCommands: [String]?
    /// `system/init`: MCP servers and their connection state.
    let mcpServers: LenientArray<McpServerStatus>?
    /// `control_response` to our `initialize` request.
    let response: ControlResponse?

    struct ControlResponse: Decodable {
        let subtype: String?
        let response: InitializePayload?
    }

    struct InitializePayload: Decodable {
        let commands: LenientArray<SlashCommand>?
        let account: ClaudeAccount?
        let models: LenientArray<ModelOption>?
    }

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
        case model
        case event
        case commands
        case terminalSlashCommands = "terminal_slash_commands"
        case mcpServers = "mcp_servers"
        case response
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        subtype = try c.decodeIfPresent(String.self, forKey: .subtype)
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError)
        result = try c.decodeIfPresent(String.self, forKey: .result)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        event = try c.decodeIfPresent(Inner.self, forKey: .event)
        // Catalog fields are best-effort: a shape we don't expect must never
        // cost the line its token/result.
        commands = try? c.decodeIfPresent(LenientArray<SlashCommand>.self, forKey: .commands)
        terminalSlashCommands = try? c.decodeIfPresent([String].self, forKey: .terminalSlashCommands)
        mcpServers = try? c.decodeIfPresent(LenientArray<McpServerStatus>.self, forKey: .mcpServers)
        response = try? c.decodeIfPresent(ControlResponse.self, forKey: .response)
    }

    /// Command-menu facts on this line: the `initialize` response (full
    /// catalog + account), a `commands_changed` refresh, or the init line's
    /// terminal-only list. Nil for every other line.
    var catalog: BackendCatalog? {
        if type == "control_response", let payload = response?.response {
            let defaultModel = payload.models?.elements.first { $0.value == "default" }?.resolvedModel
            return BackendCatalog(commands: payload.commands?.elements, account: payload.account,
                                  defaultModel: defaultModel)
        }
        if type == "system", subtype == "commands_changed", let commands {
            return BackendCatalog(commands: commands.elements)
        }
        if type == "system", subtype == "init",
           terminalSlashCommands != nil || mcpServers != nil {
            return BackendCatalog(terminalOnly: terminalSlashCommands, mcpServers: mcpServers?.elements)
        }
        return nil
    }

    /// A successful result's full text. Local commands (/context, /model…)
    /// answer with one whole assistant message and no stream deltas, so this
    /// is the only place their output appears.
    var successResultText: String? {
        guard isResult, isError != true, let result, !result.isEmpty else { return nil }
        return result
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

    /// The model id announced on the `system/init` line. Hook-related
    /// `system` lines carry no `model`, so they yield nil.
    var announcedModel: String? {
        guard type == "system", let model, !model.isEmpty else { return nil }
        return model
    }

    /// The shared event for successful stream messages. Result errors remain
    /// mapped by `ClaudeBackend` so its existing friendly error text is kept.
    var askBackendEvent: AskBackendEvent? {
        if let text = streamedText, !text.isEmpty {
            return .token(text)
        }
        if let model = announcedModel {
            return .model(model)
        }
        if isResult, isError != true {
            return .completed
        }
        return nil
    }
}
