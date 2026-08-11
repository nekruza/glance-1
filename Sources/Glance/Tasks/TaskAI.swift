import Foundation

/// AI services for the task board: enrichment (FR36–38), prioritization
/// (FR39–42), prompt→tasks decomposition (FR27). Each is a one-shot
/// provider request asking for strict JSON, parsed defensively — a malformed
/// response degrades to "no change", never corrupts the board.
///
/// Model policy (F5): mechanical JSON work requests Haiku, drafts/notes/
/// briefing/extraction request Sonnet, and agent-profile design requests Opus.
/// Providers without those aliases (currently Codex) use their CLI default.
final class TaskAI {

    private let provider: AutomationProvider

    var providerKind: AskBackendKind { provider.descriptor.kind }

    init(provider: AutomationProvider) {
        self.provider = provider
    }

    /// Compatibility bridge until AppCoordinator owns the selected provider
    /// as part of the Task 6 service-bundle migration.
    convenience init(binaryPath: String) {
        self.init(provider: ClaudeAutomationProvider(binaryPath: binaryPath,
                                                     version: "compatibility"))
    }

    // MARK: - Enrichment (FR36)

    struct Enrichment: Decodable {
        /// Echoed input id — matches the enrichment back to its task.
        var id: String?
        var title: String?
        var description: String?
        var labels: [String]?
        var taskKind: String?
        var estimate: String?
        var repoName: String?
        var agent: String?
        /// F6: uuid of an existing open task that is the SAME work (semantic
        /// dedup — catches cross-source duplicates exact keys can't).
        var duplicateOf: String?
    }

    /// "name — skills" roster lines for routing prompts.
    static func agentRoster() -> String {
        Preferences.shared.agents
            .map { "\($0.name) — \($0.skills)" }
            .joined(separator: "\n")
    }

    /// Enrich a BATCH of tasks in ONE Haiku call (F5: a pull landing 15 items
    /// used to cost 15 calls; the per-item prompt was 90% identical). Also
    /// the F6 semantic-dedup pass: `openTasks` = "uuid — title" lines of live
    /// tasks; empty skips the duplicate check.
    func enrich(items: [(id: UUID, title: String, description: String)],
                repoNames: [String], openTasks: String = "",
                completion: @escaping ([Enrichment]?) -> Void) {
        guard !items.isEmpty else {
            completion([])
            return
        }
        let dupKey = openTasks.isEmpty ? "" : """
        , "duplicateOf" (the id of the existing task below that is the SAME \
        underlying work item as this one — the same ticket, thread, meeting \
        action, or deliverable arriving from another source or phrasing; null \
        if none. Similar topic alone is NOT a duplicate)
        """
        let dupSection = openTasks.isEmpty ? "" : """


        Existing open tasks (id — title):
        \(openTasks)
        """
        let taskLines = items.map { item in
            """
            id: \(item.id.uuidString)
            title: \(item.title)
            description: \(item.description.isEmpty ? "(none)" : String(item.description.prefix(1200)))
            """
        }.joined(separator: "\n---\n")
        let prompt = """
        You enrich todo tasks. For EACH task in the input below, produce one \
        JSON object with keys: "id" (copied VERBATIM from the input), "title" \
        (cleaned, <=200 chars), "description" (markdown: 1-3 sentence context; \
        add acceptance criteria bullets ONLY if clearly inferable), "labels" \
        (array, 1-4 short lowercase tags), "taskKind" (one of: code = \
        software/repo work; writing = any communication or authored text — \
        emails, Slack/DMs, messages, docs, follow-ups, replies; research = \
        investigation/reading; other), "estimate" (one of: minutes, hour, \
        halfday, day+), "repoName" (one of \(repoNames) if the task clearly \
        belongs to that repo, else null), "agent" (the best-fit agent NAME \
        from the roster below, or null if none clearly fits)\(dupKey).
        Output ONLY a JSON array (no prose, no fences) with exactly one \
        object per input task, in input order.

        Agent roster:
        \(Self.agentRoster())\(dupSection)

        Tasks:
        \(taskLines)
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
        runJSON(prompt: prompt, model: "sonnet", completion: completion)
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
        runText(prompt: prompt, model: "sonnet", completion: completion)
    }

    // MARK: - Meeting prep notes (calendar tasks)

    /// Writes prep notes for an upcoming meeting, grounded in live work
    /// context (Granola/Slack/Jira/GitHub digests from WorkContext) plus what
    /// the task already knows. Raw markdown out (no JSON).
    func prepNotes(for task: TaskItem, workDigests: [WorkContext.Source: String],
                   boardContext: String, completion: @escaping (String?) -> Void) {
        var meeting = [
            "Title: \(task.title)",
            "Details: \(task.descriptionMD.isEmpty ? "(none)" : task.descriptionMD)"
        ]
        if !task.labels.isEmpty { meeting.append("Labels: \(task.labels.joined(separator: ", "))") }
        if let due = task.dueAt {
            meeting.append("When: \(due.formatted(date: .abbreviated, time: .shortened))")
        }

        let contextSection: String
        if workDigests.isEmpty {
            contextSection = "(no work context available — tools not connected)"
        } else {
            contextSection = WorkContext.Source.allCases.compactMap { source in
                guard let digest = workDigests[source] else { return nil }
                return "### \(source.displayName)\n\(digest)"
            }.joined(separator: "\n\n")
        }

        let prompt = """
        Write concise prep notes for the meeting below — for ME, the attendee, \
        to skim in the 5 minutes before it starts. Output ONLY markdown, no \
        preamble, no fences wrapping the whole output. Structure: \
        **Purpose** (1 line — infer from the title/agenda), \
        **Since last time** (2-5 bullets: MY relevant progress/updates from the \
        work context below — the things I'd report at this meeting), \
        **Open threads** (bullets: unresolved items from the context that this \
        meeting's people/topics touch — blockers, waiting-ons, review requests), \
        **Questions to ask** (1-3 bullets), \
        and **Who's in the room** (only if attendees are listed — group them, \
        don't repeat every email). \
        Ground every bullet in the meeting details, my task board, or the \
        work context; pick ONLY what's relevant to this meeting's topic and \
        attendees, drop the rest. Recently-done board tasks feed "Since last \
        time"; open/inbox board tasks feed "Open threads". Never invent facts.

        Meeting:
        \(meeting.joined(separator: "\n"))

        My task board (local — current state of my work):
        \(boardContext.isEmpty ? "(empty)" : boardContext)

        My recent work context (fetched live from my tools):
        \(contextSection)
        """
        runText(prompt: prompt, model: "sonnet", completion: completion)
    }

    // MARK: - Helper drafts (reply / draft / brief / approach)

    /// One-shot helper output for the non-meeting, non-code task types.
    /// Raw markdown out (no JSON envelope).
    func helperDraft(for task: TaskItem, helper: TaskHelper,
                     completion: @escaping (String?) -> Void) {
        var context = [
            "Title: \(task.title)",
            "Details: \(task.descriptionMD.isEmpty ? "(none)" : task.descriptionMD)"
        ]
        if !task.labels.isEmpty { context.append("Labels: \(task.labels.joined(separator: ", "))") }
        if let due = task.dueAt {
            context.append("Due: \(due.formatted(date: .abbreviated, time: .shortened))")
        }
        let taskBlock = context.joined(separator: "\n")

        let instruction: String
        switch helper {
        case .reply:
            instruction = """
            The task below came from a Slack message someone sent me. Write the \
            reply I should send back — ready to paste into Slack. Match the \
            sender's register (casual Slack tone), be direct, commit to \
            something concrete (what I'll do and by when, or what I need from \
            them first). Base it ONLY on the quoted context; if key info is \
            missing, the reply should ask for it. Output ONLY the message text \
            as markdown — no preamble, no options, no commentary.
            """
        case .draft:
            instruction = """
            The task below is a writing deliverable. Write a solid first draft \
            of it — the actual content, not advice about writing it. Infer \
            format and length from the task (email → an email; doc → sections; \
            post → a post). Ground everything in the details given; where facts \
            are missing, leave a clearly-marked [placeholder] rather than \
            inventing. Output ONLY the draft as markdown.
            """
        case .brief:
            instruction = """
            The task below is a research task. Write a compact research brief: \
            **Goal** (1 line), **Key questions** (3-6 bullets), **Where to \
            look** (specific sources/tools/people implied by the context), and \
            **First step** (the single next action). Ground it in the details \
            given; don't invent constraints. Output ONLY markdown.
            """
        case .approach:
            instruction = """
            Suggest how to tackle the task below: **Approach** (2-4 sentences), \
            **Steps** (3-6 checklist bullets, smallest-first), and **First \
            move** (the one thing to do right now, concrete enough to start in \
            a minute). Ground it in the details given — no invented \
            requirements. Output ONLY markdown.
            """
        case .prepNotes, .handoffPrompt:
            // Handled by dedicated methods (prepNotes / handoffPrompt).
            completion(nil)
            return
        }

        let prompt = """
        \(instruction)

        Task:
        \(taskBlock)
        """
        runText(prompt: prompt, model: "sonnet", completion: completion)
    }

    // MARK: - Morning briefing (A1)

    /// Compose the daily briefing from a pre-built local-data digest (board,
    /// inbox, review queue, meetings, momentum). Raw markdown out (no JSON).
    func morningBriefing(context: String, completion: @escaping (String?) -> Void) {
        let prompt = """
        Write my morning briefing — a 60-second skim that opens my workday. \
        Output ONLY markdown, no preamble, no fences wrapping the whole \
        output. Sections, each ONLY if it has content: \
        **Overnight** (what landed in the Inbox and how it was triaged — one \
        short bullet per item, group similar ones), \
        **Waiting on you** (what's parked in Review — what one click clears), \
        **Today's meetings** (time order, note whether prep notes are ready), \
        **Top 3 today** (the three tasks to do first, with one short clause \
        of why each — weigh due dates, priority, meetings, and momentum), \
        **Momentum** (one warm line from the stats — never guilt-trip). \
        Be specific and compact: bullets, not prose paragraphs. Ground every \
        line in the data below; never invent items or facts. Address me as \
        "you".

        Data:
        \(context)
        """
        runText(prompt: prompt, model: "sonnet", completion: completion)
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
        runJSON(prompt: prompt, model: "sonnet", completion: completion)
    }

    // MARK: - Plumbing

    /// Run one provider request and decode its text as T. Completion on main.
    private func runJSON<T: Decodable>(prompt: String, model: String?,
                                       completion: @escaping (T?) -> Void) {
        runRaw(prompt: prompt, model: model) { text in
            completion(text.flatMap { Self.decodeLenient(T.self, from: $0) })
        }
    }

    /// Run one provider request and return trimmed text as-is (markdown/prose).
    private func runText(prompt: String, model: String?,
                         completion: @escaping (String?) -> Void) {
        runRaw(prompt: prompt, model: model) { text in
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(trimmed?.isEmpty == false ? trimmed : nil)
        }
    }

    private func runRaw(prompt: String, model: String?,
                        completion: @escaping (String?) -> Void) {
        var output = ""
        var settled = false
        let choice = model.flatMap(AutomationModelChoice.init(rawValue:))
        provider.runText(AutomationRequest(prompt: prompt,
                                           model: provider.descriptor.model(for: choice))) { event in
            guard !settled else { return }
            switch event {
            case .text(let text):
                output += text
            case .completed:
                settled = true
                Self.completeOnMain(output.isEmpty ? nil : output, completion: completion)
            case .failed:
                settled = true
                Self.completeOnMain(nil, completion: completion)
            case .sessionID:
                break
            }
        }
    }

    private static func completeOnMain<T>(_ value: T, completion: @escaping (T) -> Void) {
        if Thread.isMainThread {
            completion(value)
        } else {
            DispatchQueue.main.async { completion(value) }
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
