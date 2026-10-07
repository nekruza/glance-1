import Foundation

/// Short present-tense labels for what the agent is doing between answer
/// text ("Reading files", "Running a command"), shown under the streaming
/// answer so a long tool run never looks like a stalled overlay.
enum ToolActivity {
    static let thinking = "Thinking"

    /// A Claude Code tool name from a `tool_use` content block.
    static func label(forClaudeTool name: String) -> String {
        switch name {
        case "Bash", "BashOutput", "KillShell", "PowerShell": return "Running a command"
        case "Read", "NotebookRead": return "Reading files"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Editing files"
        case "Grep", "Glob", "LS", "LSP": return "Searching the code"
        case "WebSearch": return "Searching the web"
        case "WebFetch": return "Reading a web page"
        case "Task", "Agent": return "Running a subagent"
        case "TodoWrite", "TaskCreate", "TaskUpdate": return "Planning"
        case "Skill": return "Loading a skill"
        case "ToolSearch": return "Loading tools"
        default: break
        }
        // mcp__<server>__<tool>: name the server, it's what the user connected.
        if name.hasPrefix("mcp__") {
            let parts = name.dropFirst(5).components(separatedBy: "__")
            if let server = parts.first, !server.isEmpty {
                return "Using \(server.replacingOccurrences(of: "_", with: " "))"
            }
        }
        return name.isEmpty ? "Working" : "Using \(name)"
    }

    /// A Codex `item.started` item type; nil for items that are answer text.
    static func label(forCodexItem type: String) -> String? {
        switch type {
        case "reasoning": return thinking
        case "command_execution": return "Running a command"
        case "file_change": return "Editing files"
        case "mcp_tool_call": return "Using a tool"
        case "web_search": return "Searching the web"
        case "todo_list": return "Planning"
        default: return nil
        }
    }
}
