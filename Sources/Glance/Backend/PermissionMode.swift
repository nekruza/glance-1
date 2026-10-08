import Foundation

/// Claude Code's permission modes, as the terminal's ⇧Tab cycles them. The
/// overlay starts every conversation in `.auto`; bypass is opt-in only.
enum PermissionMode: String, CaseIterable, Identifiable {
    case manual
    case acceptEdits
    case plan
    case auto
    case bypassPermissions

    static let defaultMode: PermissionMode = .auto

    var id: String { rawValue }

    /// `--permission-mode` / `set_permission_mode` value.
    var cliValue: String { rawValue }

    /// The CLI reports `manual` back as "default" on its status/init lines.
    init?(cliValue: String) {
        if cliValue == "default" { self = .manual; return }
        self.init(rawValue: cliValue)
    }

    var title: String {
        switch self {
        case .manual: return "Ask permissions"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan mode"
        case .auto: return "Auto mode"
        case .bypassPermissions: return "Bypass permissions"
        }
    }

    /// Short footer label.
    var shortTitle: String {
        switch self {
        case .manual: return "Ask"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan"
        case .auto: return "Auto"
        case .bypassPermissions: return "Bypass"
        }
    }

    var summary: String {
        switch self {
        case .manual: return "Asks before edits and commands"
        case .acceptEdits: return "Edits files freely, asks before commands"
        case .plan: return "Researches and proposes a plan, changes nothing"
        case .auto: return "Acts on its own, checks risky actions first"
        case .bypassPermissions: return "Runs everything without asking — risky"
        }
    }

    var symbol: String {
        switch self {
        case .manual: return "hand.raised"
        case .acceptEdits: return "pencil"
        case .plan: return "list.bullet.clipboard"
        case .auto: return "sparkles"
        case .bypassPermissions: return "exclamationmark.shield"
        }
    }

    /// ⇧Tab order. Bypass is left out so a keystroke can never turn it on.
    static let cycle: [PermissionMode] = [.manual, .acceptEdits, .plan, .auto]

    var next: PermissionMode {
        guard let index = Self.cycle.firstIndex(of: self) else { return Self.defaultMode }
        return Self.cycle[(index + 1) % Self.cycle.count]
    }
}

/// The CLI asking to use a tool (`control_request` → `can_use_tool`, sent
/// because Glance launches it with `--permission-prompt-tool stdio`). The
/// overlay shows it as an Allow / Deny card.
struct PermissionRequest: Equatable, Identifiable {
    let id: String
    let toolName: String
    let displayName: String
    /// The tool's input as sent, echoed back as `updatedInput` on Allow.
    let inputJSON: Data
    /// What it will act on: the command, file path or URL.
    let detail: String?
    let reason: String?
    /// ExitPlanMode's plan (Markdown), shown in place of a detail line.
    let plan: String?

    var isPlanApproval: Bool { toolName == "ExitPlanMode" }

    /// Parses a stream line; nil unless it is a `can_use_tool` request.
    static func parse(_ line: Data) -> PermissionRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "control_request",
              let id = object["request_id"] as? String,
              let request = object["request"] as? [String: Any],
              request["subtype"] as? String == "can_use_tool",
              let toolName = request["tool_name"] as? String
        else { return nil }
        let input = request["input"] as? [String: Any] ?? [:]
        let inputJSON = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
        return PermissionRequest(
            id: id,
            toolName: toolName,
            displayName: request["display_name"] as? String ?? toolName,
            inputJSON: inputJSON,
            detail: Self.detail(of: input),
            reason: request["description"] as? String ?? input["description"] as? String,
            plan: toolName == "ExitPlanMode" ? input["plan"] as? String : nil)
    }

    private static func detail(of input: [String: Any]) -> String? {
        for key in ["command", "file_path", "notebook_path", "path", "url", "pattern", "query"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}
