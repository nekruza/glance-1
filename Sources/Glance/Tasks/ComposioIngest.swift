import Foundation

/// Manual ingestion from Jira / Slack / Granola through the user's Composio
/// MCP account, driven by one `claude -p --mcp-config` call per pull.
///
/// READ-ONLY BY POLICY: Composio's router exposes one execute meta-tool for
/// reads and writes alike, so the permission layer can't split them — the
/// prompt hard-forbids any create/update/delete/send action and every pull
/// only lands tasks in the local Inbox (accept gate, FR34).
final class ComposioIngest {

    enum Source: String, CaseIterable {
        case jira = "Jira"
        case granola = "Granola"
        case slack = "Slack"
        case calendar = "Calendar"
        case github = "GitHub"
        case gmail = "Gmail"

        /// Sources enabled on a fresh install. GitHub/Gmail (and any generic
        /// app) are opt-in — each extra source is one more `claude -p` call
        /// per "Pull from all".
        static let defaultEnabled: [Source] = [.jira, .granola, .slack, .calendar]

        var taskSource: TaskSource {
            switch self {
            case .jira: return .jira
            case .granola: return .granola
            case .slack: return .slack
            case .calendar: return .calendar
            case .github: return .github
            case .gmail: return .gmail
            }
        }

        /// Normalize a Composio app name for matching: lowercase + strip the
        /// common "_mcp" / "-mcp" suffix Composio appends to some toolkits
        /// (e.g. the real Granola connection reports as "granola_mcp").
        static func normalizedApp(_ app: String) -> String {
            var a = app.lowercased()
            for suffix in ["_mcp", "-mcp", " mcp"] where a.hasSuffix(suffix) {
                a = String(a.dropLast(suffix.count))
            }
            return a
        }

        /// Which curated fetch source (if any) a connected app name maps to.
        /// Exact-match on normalized Composio toolkit slugs — NOT substring,
        /// so e.g. "cal" (Cal.com) never matches the Calendar source.
        static func match(app: String) -> Source? {
            switch normalizedApp(app) {
            case "jira":    return .jira
            case "slack":   return .slack
            case "granola": return .granola
            case "github":  return .github
            case "gmail", "googlemail", "google_mail": return .gmail
            case "googlecalendar", "google_calendar", "google-calendar", "gcal", "calendar":
                return .calendar
            default:        return nil
            }
        }
    }

    /// What a pull targets: a curated built-in source (hand-written prompt)
    /// or any other connected Composio app (templated generic prompt).
    enum FetchTarget: Hashable, Identifiable {
        case builtin(Source)
        case app(slug: String, name: String)

        var id: String { key }

        /// Stable key stored in `Preferences.enabledSources` — builtin
        /// rawValue ("Jira") or "app:<slug>" for generic apps.
        var key: String {
            switch self {
            case .builtin(let s): return s.rawValue
            case .app(let slug, _): return "app:\(slug)"
            }
        }

        var displayName: String {
            switch self {
            case .builtin(let s): return s.rawValue
            case .app(_, let name): return name
            }
        }

        var taskSource: TaskSource {
            switch self {
            case .builtin(let s): return s.taskSource
            case .app: return .external
            }
        }
    }

    struct FetchedTask: Decodable {
        var title: String
        var description: String?
        var labels: [String]?
        var taskKind: String?
        var estimate: String?
        var sourceKey: String?
        var sourceURL: String?
        var agent: String?
        /// ISO8601 datetime — calendar events set this to the meeting start
        /// time so the card can show its date, not just the "<HH:mm>" title prefix.
        var dueAt: String?
    }

    struct Result {
        var created: Int
        var skippedDuplicates: Int
        var error: String?
        /// IDs of the tasks this pull landed — auto-triage enriches exactly these.
        var createdIds: [UUID] = []
    }

    private let binaryPath: String
    /// Concurrent: "Pull from all" runs 2–3 sources at once — each pull is its
    /// own `claude` subprocess, and completions all hop back to the main actor,
    /// so nothing here needs serialization.
    private let queue = DispatchQueue(label: "com.h57q3wq0c.glance.composio",
                                      attributes: .concurrent)

    init(binaryPath: String) {
        self.binaryPath = binaryPath
    }

    /// Fetch one target and land new items in the store's Inbox. Main-thread
    /// completion with counts (dedup by sourceRef against all existing tasks).
    @MainActor
    func pull(_ target: FetchTarget, store: TaskStore, completion: @escaping (Result) -> Void) {
        let existingKeys = Set(store.tasks.compactMap { $0.sourceRef?.key })
        fetch(target) { fetched, error in
            guard let fetched else {
                completion(Result(created: 0, skippedDuplicates: 0,
                                  error: error ?? "No response — is \(target.displayName) connected in Composio?"))
                return
            }
            var created = 0
            var skipped = 0
            var createdIds: [UUID] = []
            for f in fetched {
                if let key = f.sourceKey, existingKeys.contains(key) {
                    skipped += 1
                    continue
                }
                var t = TaskItem(title: String(f.title.prefix(200)), source: target.taskSource)
                t.status = .inbox
                t.descriptionMD = f.description ?? ""
                t.labels = f.labels ?? []
                t.taskKind = TaskKind(rawValue: f.taskKind ?? "") ?? .other
                t.estimate = TaskEstimate(rawValue: f.estimate ?? "")
                if let key = f.sourceKey {
                    t.sourceRef = SourceRef(key: key, url: f.sourceURL)
                }
                if let dueAt = f.dueAt {
                    t.dueAt = ISO8601DateFormatter().date(from: dueAt)
                }
                t.agentId = AgentProfile.idFor(name: f.agent)
                t.aiFilledFields = ["description", "labels", "taskKind", "estimate", "agent"]
                createdIds.append(store.add(t).id)
                created += 1
            }
            completion(Result(created: created, skippedDuplicates: skipped, error: nil,
                              createdIds: createdIds))
        }
    }

    // MARK: - Outbound write (HARD TRUST BOUNDARY)

    /// The ONE outbound write path. It runs the same subprocess and 4-meta-tool
    /// allowlist as reads (Composio's router can't split read/write at the
    /// permission layer); safety is the single-action prompt scope PLUS the
    /// app-level approval gate. `instruction` must name exactly one action and
    /// embed the concrete target (permalink / issue key) + full final text.
    ///
    /// SECURITY: only ever call this from TaskBoardSession.approveSend, which
    /// fires solely on an explicit per-item user approval click. Never from
    /// Autopilot, pull, triage, or any timer. Replies DONE / FAILED: <reason>.
    @MainActor
    func performWrite(instruction: String, completion: @escaping (Swift.Result<Void, Error>) -> Void) {
        let prompt = """
        \(Self.writeRules)

        The one action to perform:
        \(instruction)
        """
        Self.run(binaryPath: binaryPath, prompt: prompt, on: queue) { text, error in
            guard let text else {
                completion(.failure(Self.writeError(error ?? "No response from Composio.")))
                return
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // FAILED anywhere wins; success needs the final line to be exactly
            // DONE (the prompt demands it) — prose like "already done" must
            // never mark a task sent when nothing left the machine.
            let lastLine = trimmed.components(separatedBy: .newlines)
                .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if trimmed.range(of: "FAILED", options: .caseInsensitive) == nil,
               lastLine.caseInsensitiveCompare("DONE") == .orderedSame {
                completion(.success(()))
            } else {
                let reason = trimmed.isEmpty ? "Composio didn't confirm the write." : String(trimmed.prefix(300))
                completion(.failure(Self.writeError(reason)))
            }
        }
    }

    /// Strict single-action envelope for the write prompt — the scope that
    /// keeps a write-capable meta-tool from doing more than the one approved
    /// action. Deliberately NOT `readOnlyRules` (that forbids all writes).
    static let writeRules = """
    STRICT SINGLE-ACTION RULES: Execute EXACTLY ONE write action — the one \
    described below and nothing else. Do NOT perform any additional create, \
    update, delete, send, post, transition, or modify action beyond it. Read \
    or search only the minimum needed to perform this single write. When it \
    succeeds, reply with exactly: DONE. If it cannot be completed, reply with: \
    FAILED: <short reason>. Output nothing else.
    """

    private static func writeError(_ message: String) -> NSError {
        NSError(domain: "Glance.ComposioWrite", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Connections (settings page)

    struct Connection: Decodable, Identifiable {
        var app: String
        var status: String
        var id: String { app }
        var isActive: Bool { status.lowercased().contains("active") }
    }

    /// List the account's Composio connections with statuses. Read-only.
    func listConnections(completion: @escaping ([Connection]?, String?) -> Void) {
        let prompt = """
        Use COMPOSIO_MANAGE_CONNECTIONS to list ALL connections for this \
        account (read/list only — do not create, refresh, or delete anything). \
        Output ONLY a JSON array (no prose, no fences) of \
        {"app": "<toolkit name, lowercase>", "status": "<exact status>"} — one \
        entry per app (dedupe multiple accounts to the healthiest status).
        """
        runPrompt(prompt) { text, error in
            guard let text else {
                completion(nil, error)
                return
            }
            if let parsed = TaskAI.decodeLenient([Connection].self, from: text) {
                completion(parsed, nil)
            } else {
                completion(nil, String(text.prefix(200)))
            }
        }
    }

    /// Transport for other read-only Composio consumers (WorkContext digests).
    /// Runs on the caller's queue so parallel fetches don't serialize behind
    /// this instance's pull queue.
    func runReadOnly(prompt: String, on queue: DispatchQueue,
                     completion: @escaping (String?, String?) -> Void) {
        Self.run(binaryPath: binaryPath, prompt: prompt, on: queue, completion: completion)
    }

    /// Run one read-only Composio prompt; main-thread completion with stdout.
    private func runPrompt(_ prompt: String, completion: @escaping (String?, String?) -> Void) {
        Self.run(binaryPath: binaryPath, prompt: prompt, on: queue, completion: completion)
    }

    private static func run(binaryPath: String, prompt: String, on queue: DispatchQueue,
                            completion: @escaping (String?, String?) -> Void) {
        queue.async {
            guard let configURL = Self.writeMCPConfig() else {
                DispatchQueue.main.async { completion(nil, "Composio isn't configured — set the MCP URL and API key in Settings.") }
                return
            }
            defer { try? FileManager.default.removeItem(at: configURL) }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binaryPath)
            proc.arguments = [
                "-p",
                "--mcp-config", configURL.path,
                "--strict-mcp-config",
                "--allowedTools", "mcp__composio__COMPOSIO_SEARCH_TOOLS",
                "mcp__composio__COMPOSIO_GET_TOOL_SCHEMAS",
                "mcp__composio__COMPOSIO_MULTI_EXECUTE_TOOL",
                "mcp__composio__COMPOSIO_MANAGE_CONNECTIONS"
            ]
            proc.currentDirectoryURL = FileManager.default.temporaryDirectory
            let inPipe = Pipe()
            let out = Pipe()
            proc.standardInput = inPipe
            proc.standardOutput = out
            proc.standardError = Pipe()
            let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 240, execute: killer)
            do {
                try proc.run()
                if let data = prompt.data(using: .utf8) {
                    try? inPipe.fileHandleForWriting.write(contentsOf: data)
                }
                try? inPipe.fileHandleForWriting.close()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                killer.cancel()
                let text = proc.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
                DispatchQueue.main.async {
                    completion(text, text == nil ? "Composio call failed (claude exited \(proc.terminationStatus))." : nil)
                }
            } catch {
                killer.cancel()
                DispatchQueue.main.async { completion(nil, error.localizedDescription) }
            }
        }
    }

    // MARK: - Fetch (background)

    private func fetch(_ target: FetchTarget, completion: @escaping ([FetchedTask]?, String?) -> Void) {
        queue.async { [binaryPath] in
            guard let configURL = Self.writeMCPConfig() else {
                DispatchQueue.main.async { completion(nil, "Composio isn't configured — set the MCP URL and API key in Settings.") }
                return
            }
            defer { try? FileManager.default.removeItem(at: configURL) }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binaryPath)
            // Prompt goes via STDIN — --allowedTools is variadic and would
            // swallow a trailing positional prompt argument.
            proc.arguments = [
                "-p",
                "--mcp-config", configURL.path,
                "--strict-mcp-config",
                "--allowedTools", "mcp__composio__COMPOSIO_SEARCH_TOOLS",
                "mcp__composio__COMPOSIO_GET_TOOL_SCHEMAS",
                "mcp__composio__COMPOSIO_MULTI_EXECUTE_TOOL",
                "mcp__composio__COMPOSIO_MANAGE_CONNECTIONS"
            ]
            proc.currentDirectoryURL = FileManager.default.temporaryDirectory

            let inPipe = Pipe()
            let out = Pipe()
            proc.standardInput = inPipe
            proc.standardOutput = out
            proc.standardError = Pipe()

            // Generous cap — tool discovery + a few API reads.
            let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 240, execute: killer)

            do {
                try proc.run()
                if let data = Self.prompt(for: target).data(using: .utf8) {
                    try? inPipe.fileHandleForWriting.write(contentsOf: data)
                }
                try? inPipe.fileHandleForWriting.close()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                killer.cancel()
                guard proc.terminationStatus == 0,
                      let text = String(data: data, encoding: .utf8) else {
                    DispatchQueue.main.async {
                        completion(nil, "Pull failed (claude exited \(proc.terminationStatus)).")
                    }
                    return
                }
                let parsed = TaskAI.decodeLenient([FetchedTask].self, from: text)
                DispatchQueue.main.async {
                    if let parsed {
                        completion(parsed, nil)
                    } else {
                        // Model replied with prose (e.g. "app not connected").
                        completion(nil, String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)))
                    }
                }
            } catch {
                killer.cancel()
                DispatchQueue.main.async { completion(nil, error.localizedDescription) }
            }
        }
    }

    /// MCP config written fresh per pull from Preferences (URL + key editable
    /// in Settings). 0600 perms — it carries the API key.
    private static func writeMCPConfig() -> URL? {
        let prefs = Preferences.shared
        guard !prefs.composioKey.isEmpty, !prefs.composioURL.isEmpty else { return nil }
        let config: [String: Any] = [
            "mcpServers": [
                "composio": [
                    "type": "http",
                    "url": prefs.composioURL,
                    "headers": ["Authorization": "Bearer \(prefs.composioKey)"]
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-mcp-\(UUID().uuidString.prefix(8)).json")
        do {
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    static let readOnlyRules = """
    STRICT READ-ONLY RULES: You may ONLY call read/list/search/get actions. \
    NEVER call any action that creates, updates, deletes, sends, posts, \
    transitions, comments, or modifies ANYTHING in any external system. If a \
    needed action would write, skip it. You are fetching data only.
    """

    private static var outputRules: String {
        """
        Output ONLY a JSON array (no prose, no fences) of task objects: \
        {"title": "<imperative, <=120 chars>", "description": "<markdown context, \
        include source details/links>", "labels": [1-4 short lowercase tags], \
        "taskKind": "code|writing|research|other", "estimate": \
        "minutes|hour|halfday|day+", "sourceKey": "<stable unique id, see below>", \
        "sourceURL": "<deep link if available, else null>", "agent": "<best-fit \
        agent NAME from this roster, or null: \(TaskAI.agentRoster().replacingOccurrences(of: "\n", with: "; "))>", \
        "dueAt": "<ISO8601 datetime, or null>"}. \
        Empty array [] if nothing found. If the app is NOT connected in Composio, \
        output the single line: NOT_CONNECTED.
        """
    }

    private static func prompt(for target: FetchTarget) -> String {
        switch target {
        case .builtin(let source):
            return prompt(for: source)
        case .app(let slug, let name):
            return """
            Using the composio tools for \(name) (toolkit "\(slug)"), fetch \
            recent items (last 7 days) that are assigned to me, mention me, or \
            otherwise need action FROM ME. Discover the toolkit's read/list/\
            search actions with COMPOSIO_SEARCH_TOOLS first. Read actions \
            only. \(readOnlyRules)
            One task per actionable item — ignore FYIs and do not invent \
            tasks. sourceKey = "\(slug):<stable item id>"; sourceURL = a deep \
            link if available. Mention \(name) and include source context in \
            the description. \(outputRules)
            """
        }
    }

    private static func prompt(for source: Source) -> String {
        switch source {
        case .jira:
            return """
            Using the composio tools, fetch MY open Jira issues: assigned to me, \
            status not done/closed/resolved, updated in the last 30 days. Use \
            Jira search/read actions only. \(readOnlyRules)
            One task per issue. sourceKey = the Jira issue key (e.g. "CW-123"); \
            sourceURL = the issue's browse URL. Put the issue summary in the \
            title (prefix with the key), and status/priority/reporter context \
            in the description. \(outputRules)
            """
        case .granola:
            return """
            Using the composio tools, fetch my Granola meetings from the last \
            3 days and extract action items that belong to ME (committed to, \
            assigned, or clearly mine). Read actions only. \(readOnlyRules)
            One task per action item — do not invent tasks. sourceKey = \
            "<meeting id or title>#<short slug of the action item>". Include \
            the meeting name and any deadline in the description. \(outputRules)
            """
        case .slack:
            return """
            Using the composio tools, fetch my recent Slack activity (last 2 \
            days): messages mentioning me and direct messages, and extract \
            things that need action FROM ME. Read actions only. \(readOnlyRules)
            IMPORTANT — expand threads: whenever a message has replies (it has \
            a thread_ts, a reply_count > 0, or a "N replies" indicator), you \
            MUST fetch the full thread with the replies action (e.g. Slack \
            conversations.replies / fetch-thread, passing the channel and the \
            parent thread_ts) and read EVERY reply before deciding. The \
            actionable detail (specs, templates, requested deliverables) is \
            often in a reply, not the parent — the parent may only be a \
            mention or heads-up. Base the task on the whole thread, and quote \
            the specific reply that contains the ask, preserving its bold \
            headings / bullet structure in the description markdown. \
            One task per actionable item — ignore FYIs and threads that are \
            fully resolved. sourceKey = the actionable message's permalink or \
            channel+ts (the reply's ts when the ask is in a reply); sourceURL \
            = that permalink. \(outputRules)
            """
        case .calendar:
            return """
            Using the composio tools, fetch my Google Calendar events for \
            TODAY (primary calendar, from now until end of day). Read actions \
            only. \(readOnlyRules)
            Create one task per meeting/call today. Skip: events I've \
            declined, all-day placeholders (focus time, OOO, holidays), and \
            events already ended. Title format: "<HH:mm> <event title>". \
            Description: attendees, meet/zoom link if present, and the \
            agenda/description excerpt. taskKind = "other"; estimate = the \
            event duration bucket. dueAt = the event's start datetime, ISO8601 \
            with timezone. sourceKey = the calendar event id; \
            sourceURL = the event's htmlLink. \(outputRules)
            """
        case .github:
            return """
            Using the composio tools, fetch MY current GitHub work: pull \
            requests where my review is requested, my open pull requests, and \
            issues assigned to me — updated in the last 30 days. Use GitHub \
            search/read actions only. \(readOnlyRules)
            One task per PR/issue. sourceKey = "<owner>/<repo>#<number>"; \
            sourceURL = the PR/issue html URL. Prefix the title with the repo \
            short name. Put state, labels, author and requested-reviewer \
            context in the description. taskKind = "code" for PRs and code \
            issues. \(outputRules)
            """
        case .gmail:
            return """
            Using the composio tools, fetch my recent Gmail inbox (last 3 \
            days) and extract emails that need action FROM ME — a reply, a \
            decision, or a deadline. Read actions only. \(readOnlyRules)
            Ignore newsletters, automated notifications, receipts, and \
            pure-FYI mail. One task per actionable email. Title = imperative \
            summary of the ask, not the subject line verbatim. Include \
            sender, subject and the specific ask in the description. \
            sourceKey = the Gmail message id; sourceURL = \
            "https://mail.google.com/mail/u/0/#inbox/<message id>". \
            taskKind = "writing". \(outputRules)
            """
        }
    }
}
