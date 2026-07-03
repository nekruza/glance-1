import Foundation

/// Bridge from the ask overlay to the task board (V2 FR25 flavor): the ask
/// session is told, via system prompt, to emit `glance-task` fenced JSON
/// blocks whenever the user asks for a task to be created — including from
/// screenshot context. Glance intercepts the blocks out of the finished
/// answer, creates tasks, and replaces the blocks with a confirmation line.
enum TaskCapture {

    /// Appended to the ask-overlay session's system prompt.
    static let systemPrompt = """
    You have one extra capability inside the Glance app: creating tasks on the \
    user's local task board. When (and ONLY when) the user explicitly asks to \
    add/create/save a task or todo — e.g. "add a task to fix this", "put this \
    on my todo list", possibly referring to the attached screenshot — emit one \
    fenced code block per task, language tag exactly `glance-task`, containing \
    a single JSON object: {"title": "<imperative, <=120 chars>", \
    "description": "<markdown context; if a screenshot was attached, describe \
    the relevant on-screen context here so the task is self-contained>", \
    "labels": ["<1-4 short lowercase tags>"], "taskKind": "code|writing|research|other", \
    "estimate": "minutes|hour|halfday|day+"}. Keep any surrounding prose brief. \
    Do not emit glance-task blocks for anything the user didn't ask to track.
    """

    struct CapturedTask: Decodable {
        var title: String
        var description: String?
        var labels: [String]?
        var taskKind: String?
        var estimate: String?
    }

    /// Extract glance-task blocks from a finished answer. Returns the cleaned
    /// answer (blocks replaced with confirmation lines) and the parsed tasks.
    static func extract(from answer: String) -> (cleaned: String, tasks: [CapturedTask]) {
        guard answer.contains("```glance-task") else { return (answer, []) }
        var tasks: [CapturedTask] = []
        var cleanedLines: [String] = []
        var blockLines: [String] = []
        var inBlock = false

        for line in answer.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inBlock, trimmed.hasPrefix("```glance-task") {
                inBlock = true
                blockLines = []
                continue
            }
            if inBlock, trimmed.hasPrefix("```") {
                inBlock = false
                let json = blockLines.joined(separator: "\n")
                if let data = json.data(using: .utf8),
                   let task = try? JSONDecoder().decode(CapturedTask.self, from: data),
                   !task.title.trimmingCharacters(in: .whitespaces).isEmpty {
                    tasks.append(task)
                    cleanedLines.append("✓ **Added to your tasks:** \(task.title)")
                } else {
                    cleanedLines.append("⚠︎ Couldn't parse a task the assistant tried to create.")
                }
                continue
            }
            if inBlock {
                blockLines.append(line)
            } else {
                cleanedLines.append(line)
            }
        }
        // Unterminated block (stream cut off): drop it silently.
        return (cleanedLines.joined(separator: "\n"), tasks)
    }

    /// Convert a captured task into a board item. Explicit user command →
    /// straight to `ready` (the Inbox gate is for ambient ingestion; this was
    /// a direct instruction, same trust level as typing it on the board).
    static func makeTaskItem(_ captured: CapturedTask) -> TaskItem {
        var t = TaskItem(title: String(captured.title.prefix(200)), source: .prompt)
        t.descriptionMD = captured.description ?? ""
        t.labels = captured.labels ?? []
        t.taskKind = TaskKind(rawValue: captured.taskKind ?? "") ?? .other
        t.estimate = TaskEstimate(rawValue: captured.estimate ?? "")
        t.aiFilledFields = ["description", "labels", "taskKind", "estimate"]
        return t
    }
}
