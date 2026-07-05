import Foundation

/// AI services for the task board: enrichment (FR36–38), prioritization
/// (FR39–42), prompt→tasks decomposition (FR27). Each is a one-shot
/// `claude -p` call requesting strict JSON, parsed defensively — a malformed
/// response degrades to "no change", never corrupts the board.
final class TaskAI {

    private let binaryPath: String
    private let queue = DispatchQueue(label: "com.h57q3wq0c.glance.taskai", attributes: .concurrent)

    init(binaryPath: String) {
        self.binaryPath = binaryPath
    }

    // MARK: - Enrichment (FR36)

    struct Enrichment: Decodable {
        var title: String?
        var description: String?
        var labels: [String]?
        var taskKind: String?
        var estimate: String?
        var repoName: String?
        var agent: String?
    }

    /// "name — skills" roster lines for routing prompts.
    static func agentRoster() -> String {
        Preferences.shared.agents
            .map { "\($0.name) — \($0.skills)" }
            .joined(separator: "\n")
    }

    func enrich(title: String, description: String, repoNames: [String],
                completion: @escaping (Enrichment?) -> Void) {
        let prompt = """
        You enrich a todo task. Given its raw title/description, produce JSON only \
        (no prose, no fences) with keys: "title" (cleaned, <=200 chars), \
        "description" (markdown: 1-3 sentence context; add acceptance criteria \
        bullets ONLY if clearly inferable), "labels" (array, 1-4 short lowercase \
        tags), "taskKind" (one of: code, writing, research, other), "estimate" \
        (one of: minutes, hour, halfday, day+), "repoName" (one of \(repoNames) \
        if the task clearly belongs to that repo, else null), "agent" (the \
        best-fit agent NAME from the roster below, or null if none clearly fits).

        Agent roster:
        \(Self.agentRoster())

        Task title: \(title)
        Task description: \(description.isEmpty ? "(none)" : description)
        """
        runJSON(prompt: prompt, model: "haiku", completion: completion)
    }

    // MARK: - Prioritization (FR39)

    struct PriorityEntry: Decodable {
        var id: String
        var priority: String
        var rationale: String
    }

    /// Compact board state in, ordered ids + rationale out. Pinned tasks are
    /// sent for context but the store ignores rank changes on them (FR41).
    func prioritize(board: [TaskItem], completion: @escaping ([PriorityEntry]?) -> Void) {
        let lines = board.map { t -> String in
            var bits = ["id=\(t.id.uuidString)", "title=\(t.title.prefix(80))"]
            if !t.labels.isEmpty { bits.append("labels=\(t.labels.joined(separator: "|"))") }
            if let e = t.estimate { bits.append("estimate=\(e.rawValue)") }
            if let d = t.dueAt { bits.append("due=\(ISO8601DateFormatter().string(from: d))") }
            bits.append("kind=\(t.taskKind.rawValue)")
            bits.append("status=\(t.status.rawValue)")
            if t.isPinned { bits.append("PINNED") }
            return bits.joined(separator: " · ")
        }.joined(separator: "\n")

        let prompt = """
        You prioritize a personal task board. Order tasks by what the user should \
        do first. Consider: due dates, blockers/urgency language, small-quick-wins \
        unblocking others, staleness. Output JSON only (no prose, no fences): an \
        array of ALL task objects in your recommended order, each \
        {"id": "<uuid>", "priority": "P0|P1|P2|P3", "rationale": "<one short \
        sentence why this position>"}. Include every task exactly once.

        Tasks:
        \(lines)
        """
        runJSON(prompt: prompt, model: "haiku", completion: completion)
    }

    // MARK: - Prompt → tasks decomposition (FR27)

    struct DecomposedTask: Decodable {
        var title: String
        var description: String?
        var labels: [String]?
        var taskKind: String?
        var estimate: String?
        var agent: String?
    }

    func decompose(prompt userText: String, completion: @escaping ([DecomposedTask]?) -> Void) {
        let prompt = """
        Decompose the following braindump/notes into discrete actionable tasks. \
        Output JSON only (no prose, no fences): array of 1-10 objects \
        {"title": "<imperative, <=120 chars>", "description": "<markdown context \
        from the source text>", "labels": [..], "taskKind": "code|writing|research|other", \
        "estimate": "minutes|hour|halfday|day+", "agent": "<best-fit agent NAME \
        from the roster below, or null>"}. Split independent work items; \
        don't invent work not implied by the text.

        Agent roster:
        \(Self.agentRoster())

        Text:
        \(userText)
        """
        runJSON(prompt: prompt, model: nil, completion: completion)
    }

    // MARK: - Agent generation (Settings ▸ Agents)

    struct GeneratedAgent: Decodable {
        var name: String
        var icon: String?
        var skills: String
        var systemPrompt: String
        var preferredModel: String?
        var allowedTools: [String]?
    }

    /// Opus writes a full agent profile from a natural-language request.
    func generateAgent(request: String, existingNames: [String],
                       completion: @escaping (GeneratedAgent?) -> Void) {
        let prompt = """
        Design an AI agent profile for a personal task-execution system. The \
        user describes what they need; you produce the profile. Output JSON \
        only (no prose, no fences): {"name": "<1-2 words, distinct from: \
        \(existingNames.joined(separator: ", "))>", "icon": "<exactly ONE \
        emoji that fits the role, e.g. 📊 ✍️ 🔍 💻 🧠 🎨 ✉️>", "skills": "<one line \
        describing what tasks it's best at — used to route tasks to it>", \
        "systemPrompt": "<150-350 words: persona, method/discipline, quality \
        bar, output expectations. Write it as instructions to the agent.>", \
        "preferredModel": "haiku|sonnet|opus|null (null = default; haiku for \
        mechanical work, sonnet for routine, opus for hard reasoning)", \
        "allowedTools": [subset of: Bash, Edit, Write, Read, Glob, Grep, \
        WebFetch, WebSearch — only what the role needs; least privilege]}.

        User's request: \(request)
        """
        runJSON(prompt: prompt, model: "opus", completion: completion)
    }

    // MARK: - Handoff prompt (code tasks → external AI)

    /// Writes a self-contained coding prompt the user can paste into another
    /// AI assistant. Raw markdown out (no JSON envelope).
    func handoffPrompt(for task: TaskItem, repoName: String?, agent: AgentProfile?,
                       completion: @escaping (String?) -> Void) {
        var context = [
            "Title: \(task.title)",
            "Description: \(task.descriptionMD.isEmpty ? "(none)" : task.descriptionMD)"
        ]
        if !task.labels.isEmpty { context.append("Labels: \(task.labels.joined(separator: ", "))") }
        if let repoName { context.append("Repository: \(repoName)") }
        if let path = task.workspacePath { context.append("Repo path: \(path)") }
        if let agent { context.append("Intended skill profile: \(agent.name) — \(agent.skills)") }

        let prompt = """
        Write a prompt I can paste into an AI coding assistant (Claude Code, \
        Cursor, etc.) to get the task below done. Output ONLY the prompt text \
        as markdown — no preamble, no commentary, no code fences wrapping the \
        whole output. Structure it with: goal, context, requirements (as \
        acceptance-criteria bullets), constraints, and a suggested approach \
        only if clearly inferable. Be specific and concrete; do NOT invent \
        requirements the task doesn't imply.

        Task:
        \(context.joined(separator: "\n"))
        """
        runText(prompt: prompt, model: nil, completion: completion)
    }

    // MARK: - Meeting action items (transcript pane reader)

    /// Extract ONLY the user's own action items from meeting notes.
    func extractActionItems(meetingText: String, completion: @escaping ([DecomposedTask]?) -> Void) {
        let prompt = """
        From these meeting notes/transcript, extract action items that belong to \
        ME (the note-taker — items I committed to, was assigned, or clearly own; \
        speakers may be unlabeled, use judgment). Output JSON only (no prose, no \
        fences): array of 0-8 objects {"title": "<imperative, <=120 chars>", \
        "description": "<context from the meeting incl. any deadline>", \
        "labels": [..], "taskKind": "code|writing|research|other", \
        "estimate": "minutes|hour|halfday|day+", "agent": "<best-fit agent NAME \
        from the roster below, or null>"}. Do NOT invent tasks; empty \
        array if none are mine.

        Agent roster:
        \(Self.agentRoster())

        Notes:
        \(String(meetingText.prefix(30_000)))
        """
        runJSON(prompt: prompt, model: nil, completion: completion)
    }

    // MARK: - Plumbing

    /// Run one `claude -p` call and decode its stdout as T. Completion on main.
    private func runJSON<T: Decodable>(prompt: String, model: String?,
                                       completion: @escaping (T?) -> Void) {
        runRaw(prompt: prompt, model: model) { text in
            completion(text.flatMap { Self.decodeLenient(T.self, from: $0) })
        }
    }

    /// Run one `claude -p` call and return trimmed stdout as-is (markdown/prose).
    private func runText(prompt: String, model: String?,
                         completion: @escaping (String?) -> Void) {
        runRaw(prompt: prompt, model: model) { text in
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(trimmed?.isEmpty == false ? trimmed : nil)
        }
    }

    private func runRaw(prompt: String, model: String?,
                        completion: @escaping (String?) -> Void) {
        queue.async { [binaryPath] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binaryPath)
            var args = ["-p"]
            if let model { args += ["--model", model] }
            args.append(prompt)
            proc.arguments = args
            proc.currentDirectoryURL = FileManager.default.temporaryDirectory

            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()

            var result: String?
            do {
                try proc.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    result = String(data: data, encoding: .utf8)
                }
            } catch {
                // fall through with nil
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Models sometimes wrap JSON in fences or prose despite instructions —
    /// extract the outermost JSON value before decoding.
    static func decodeLenient<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates: [String] = [
            trimmed,
            Self.stripFences(trimmed),
            Self.extractJSON(trimmed, open: "[", close: "]"),
            Self.extractJSON(trimmed, open: "{", close: "}")
        ].compactMap { $0 }
        for c in candidates {
            if let data = c.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(T.self, from: data) {
                return decoded
            }
        }
        return nil
    }

    private static func stripFences(_ s: String) -> String? {
        guard s.hasPrefix("```") else { return nil }
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeFirst()
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func extractJSON(_ s: String, open: Character, close: Character) -> String? {
        guard let start = s.firstIndex(of: open), let end = s.lastIndex(of: close),
              start < end else { return nil }
        return String(s[start...end])
    }
}
