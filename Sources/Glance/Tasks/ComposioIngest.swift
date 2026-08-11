import Foundation

/// Manual ingestion from Jira / Slack / Granola through the user's Composio
/// MCP account, driven by the selected automation provider per pull.
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

    private final class ActiveRequest {
        var cancellation: AutomationCancellation?
        var text = ""
        var finished = false
    }

    private let provider: AutomationProvider
    private let activeLock = NSLock()
    private var activeRequests: [UUID: ActiveRequest] = [:]
    /// Concurrent: "Pull from all" runs 2–3 sources at once — each pull is its
    /// own provider subprocess, and completions all hop back to the main actor,
    /// so nothing here needs serialization.
    private let queue = DispatchQueue(label: "com.h57q3wq0c.glance.composio",
                                      attributes: .concurrent)

    init(provider: AutomationProvider) {
        self.provider = provider
    }

    /// Compatibility bridge until AppCoordinator owns the selected provider
    /// as part of the Task 6 service-bundle migration.
    convenience init(binaryPath: String) {
        self.init(provider: ClaudeAutomationProvider(binaryPath: binaryPath,
                                                     version: "compatibility"))
    }

    deinit {
        cancelActiveRequests()
    }

    /// Fetch one target and land new items in the store's Inbox. Main-thread
    /// completion with counts (dedup by sourceRef against all existing tasks).
    @MainActor
    func pull(_ target: FetchTarget, store: TaskStore, completion: @escaping (Result) -> Void) {
        // Dedup identity: keys AND urls, case-folded, in one set. The model
        // authors sourceKey and sometimes drifts format between pulls (Slack
        // permalink vs channel+ts, Granola slugs) — an item whose key OR deep
        // link matches anything we've seen is the same item. Also bridges key
        // format changes: an old permalink-key still matches a new item's URL.
        var existingIds = Set<String>()
        for t in store.tasks {
            if let key = t.sourceRef?.key, !key.isEmpty { existingIds.insert(key.lowercased()) }
            if let url = t.sourceRef?.url, !url.isEmpty { existingIds.insert(url.lowercased()) }
        }
        // Incremental window: ask only for items updated since the last
        // successful pull. Stamped with the pull's START time so items
        // updated mid-pull aren't missed next time; only on success, so a
        // failed pull retries the full window.
        let startedAt = Date()
        let since = Preferences.shared.pullLastRun(target.key)
        fetch(target, since: since) { fetched, error in
            guard let fetched else {
                completion(Result(created: 0, skippedDuplicates: 0,
                                  error: error ?? "No response — is \(target.displayName) connected in Composio?"))
                return
            }
            var created = 0
            var skipped = 0
            var createdIds: [UUID] = []
            for f in fetched {
                let key = f.sourceKey?.lowercased() ?? ""
                let url = f.sourceURL?.lowercased() ?? ""
                if (!key.isEmpty && existingIds.contains(key))
                    || (!url.isEmpty && existingIds.contains(url)) {
                    skipped += 1
                    continue
                }
                // Also dedupe within this batch — a model sometimes lists the
                // same item twice.
                if !key.isEmpty { existingIds.insert(key) }
                if !url.isEmpty { existingIds.insert(url) }
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
            Preferences.shared.setPullLastRun(target.key, startedAt)
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
        runComposio(prompt: prompt, on: queue) { text, error in
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
        runComposio(prompt: prompt, on: queue, completion: completion)
    }

    /// Run one read-only Composio prompt; main-thread completion with stdout.
    private func runPrompt(_ prompt: String, completion: @escaping (String?, String?) -> Void) {
        runComposio(prompt: prompt, on: queue, completion: completion)
    }

    private func runComposio(prompt: String, on queue: DispatchQueue,
                             completion: @escaping (String?, String?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let prefs = Preferences.shared
            guard !prefs.composioKey.isEmpty, !prefs.composioURL.isEmpty else {
                DispatchQueue.main.async {
                    completion(nil, "Composio isn't configured — set the MCP URL and API key in Settings.")
                }
                return
            }

            let id = UUID()
            let active = ActiveRequest()
            self.activeLock.lock()
            self.activeRequests[id] = active
            self.activeLock.unlock()

            let cancellation = self.provider.runComposio(
                ComposioAutomationRequest(prompt: prompt, endpoint: prefs.composioURL),
                token: prefs.composioKey
            ) { [weak self, weak active] event in
                self?.handle(event, id: id, active: active, completion: completion)
            }

            self.activeLock.lock()
            if active.finished {
                self.activeLock.unlock()
                cancellation.cancel()
            } else {
                active.cancellation = cancellation
                self.activeLock.unlock()
            }
        }
    }

    private func handle(_ event: AutomationEvent, id: UUID, active: ActiveRequest?,
                        completion: @escaping (String?, String?) -> Void) {
        guard let active else { return }
        var result: (String?, String?)?
        activeLock.lock()
        guard !active.finished else {
            activeLock.unlock()
            return
        }
        switch event {
        case .text(let text):
            active.text += text
        case .completed:
            active.finished = true
            activeRequests[id] = nil
            result = (active.text, nil)
        case .failed(let message):
            active.finished = true
            activeRequests[id] = nil
            result = (nil, message)
        case .sessionID:
            break
        }
        activeLock.unlock()

        if let result {
            DispatchQueue.main.async { completion(result.0, result.1) }
        }
    }

    private func cancelActiveRequests() {
        activeLock.lock()
        let cancellations = activeRequests.values.compactMap(\.cancellation)
        activeRequests.removeAll()
        activeLock.unlock()
        cancellations.forEach { $0.cancel() }
    }

    static func failureMessage(kind: AskBackendKind, status: Int32) -> String {
        "Composio call failed (\(kind.displayName) exited \(status))."
    }

    // MARK: - Fetch (background)

    private func fetch(_ target: FetchTarget, since: Date? = nil,
                       completion: @escaping ([FetchedTask]?, String?) -> Void) {
        runComposio(prompt: Self.prompt(for: target, since: since), on: queue) { text, error in
            guard let text else {
                completion(nil, error)
                return
            }
            if let parsed = TaskAI.decodeLenient([FetchedTask].self, from: text) {
                completion(parsed, nil)
            } else {
                // Model replied with prose (e.g. "app not connected").
                completion(nil, String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)))
            }
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

    /// Fetch-window clause: a fixed default for first pulls, "since <my last
    /// pull>" afterwards — narrow windows shrink the tool results that
    /// dominate an MCP session's token cost. 1 h overlap absorbs clock skew
    /// and mid-pull updates (dedup eats the repeats); the default window is
    /// the widest we ever ask for.
    private static func window(defaultDays: Int, since: Date?) -> String {
        let floor = Date().addingTimeInterval(TimeInterval(-defaultDays * 86_400))
        guard let since else { return "in the last \(defaultDays) days" }
        let effective = max(since.addingTimeInterval(-3600), floor)
        return "since \(ISO8601DateFormatter().string(from: effective)) " +
               "(my previous pull — ONLY items created or updated after this)"
    }

    private static func prompt(for target: FetchTarget, since: Date?) -> String {
        switch target {
        case .builtin(let source):
            return prompt(for: source, since: since)
        case .app(let slug, let name):
            return """
            Using the composio tools for \(name) (toolkit "\(slug)"), fetch \
            items \(window(defaultDays: 7, since: since)) that are assigned \
            to me, mention me, or otherwise need action FROM ME. Discover the \
            toolkit's read/list/search actions with COMPOSIO_SEARCH_TOOLS \
            first. Read actions only. \(readOnlyRules)
            One task per actionable item — ignore FYIs and do not invent \
            tasks. sourceKey = "\(slug):<stable item id>"; sourceURL = a deep \
            link if available. Mention \(name) and include source context in \
            the description. \(outputRules)
            """
        }
    }

    private static func prompt(for source: Source, since: Date?) -> String {
        switch source {
        case .jira:
            return """
            Using the composio tools, fetch MY open Jira issues: assigned to me, \
            status not done/closed/resolved, updated \(window(defaultDays: 30, since: since)). Use \
            Jira search/read actions only. \(readOnlyRules)
            One task per issue. sourceKey = the Jira issue key (e.g. "CW-123"); \
            sourceURL = the issue's browse URL. Put the issue summary in the \
            title (prefix with the key), and status/priority/reporter context \
            in the description. \(outputRules)
            """
        case .granola:
            return """
            Using the composio tools, fetch my Granola meetings \
            \(window(defaultDays: 3, since: since)) and extract action items \
            that belong to ME (committed to, assigned, or clearly mine). Read \
            actions only. \(readOnlyRules)
            One task per action item — do not invent tasks. sourceKey = \
            "<meeting id, or exact meeting title if no id>#<slug>" where slug \
            is the action item's first 6 words, lowercased, every run of \
            non-alphanumeric characters replaced by a single dash (e.g. \
            "Follow up with Ben re: SSO" → "follow-up-with-ben-re-sso"). \
            Deterministic: the SAME action item must produce the SAME key on \
            every pull. Include the meeting name and any deadline in the \
            description. \(outputRules)
            """
        case .slack:
            return """
            Using the composio tools, fetch my Slack activity \
            \(window(defaultDays: 2, since: since)): messages mentioning me \
            and direct messages, and extract things that need action FROM ME. \
            Read actions only. \(readOnlyRules)
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
            fully resolved. sourceKey = "<channel id>:<parent message ts>" — \
            ALWAYS the thread's PARENT message ts (never a reply's ts), so the \
            same thread produces the same key on every pull even when the ask \
            is in a reply. sourceURL = the permalink of the message containing \
            the ask. \(outputRules)
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
            issues assigned to me — updated \(window(defaultDays: 30, since: since)). Use GitHub \
            search/read actions only. \(readOnlyRules)
            One task per PR/issue. sourceKey = "<owner>/<repo>#<number>"; \
            sourceURL = the PR/issue html URL. Prefix the title with the repo \
            short name. Put state, labels, author and requested-reviewer \
            context in the description. taskKind = "code" for PRs and code \
            issues. \(outputRules)
            """
        case .gmail:
            return """
            Using the composio tools, fetch my Gmail inbox \
            (\(window(defaultDays: 3, since: since))) and extract emails that \
            need action FROM ME — a reply, a decision, or a deadline. Read \
            actions only. \(readOnlyRules)
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
