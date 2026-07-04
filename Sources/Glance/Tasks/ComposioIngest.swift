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

        var taskSource: TaskSource {
            switch self {
            case .jira: return .jira
            case .granola: return .granola
            case .slack: return .slack
            case .calendar: return .calendar
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
    }

    struct Result {
        var created: Int
        var skippedDuplicates: Int
        var error: String?
    }

    private let binaryPath: String
    private let queue = DispatchQueue(label: "com.h57q3wq0c.glance.composio")

    init(binaryPath: String) {
        self.binaryPath = binaryPath
    }

    /// Fetch one source and land new items in the store's Inbox. Main-thread
    /// completion with counts (dedup by sourceRef against all existing tasks).
    @MainActor
    func pull(_ source: Source, store: TaskStore, completion: @escaping (Result) -> Void) {
        let existingKeys = Set(store.tasks.compactMap { $0.sourceRef?.key })
        fetch(source) { fetched, error in
            guard let fetched else {
                completion(Result(created: 0, skippedDuplicates: 0,
                                  error: error ?? "No response — is \(source.rawValue) connected in Composio?"))
                return
            }
            var created = 0
            var skipped = 0
            for f in fetched {
                if let key = f.sourceKey, existingKeys.contains(key) {
                    skipped += 1
                    continue
                }
                var t = TaskItem(title: String(f.title.prefix(200)), source: source.taskSource)
                t.status = .inbox
                t.descriptionMD = f.description ?? ""
                t.labels = f.labels ?? []
                t.taskKind = TaskKind(rawValue: f.taskKind ?? "") ?? .other
                t.estimate = TaskEstimate(rawValue: f.estimate ?? "")
                if let key = f.sourceKey {
                    t.sourceRef = SourceRef(key: key, url: f.sourceURL)
                }
                t.aiFilledFields = ["description", "labels", "taskKind", "estimate"]
                _ = store.add(t)
                created += 1
            }
            completion(Result(created: created, skippedDuplicates: skipped, error: nil))
        }
    }

    // MARK: - Fetch (background)

    private func fetch(_ source: Source, completion: @escaping ([FetchedTask]?, String?) -> Void) {
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
                if let data = Self.prompt(for: source).data(using: .utf8) {
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

    private static let readOnlyRules = """
    STRICT READ-ONLY RULES: You may ONLY call read/list/search/get actions. \
    NEVER call any action that creates, updates, deletes, sends, posts, \
    transitions, comments, or modifies ANYTHING in any external system. If a \
    needed action would write, skip it. You are fetching data only.
    """

    private static let outputRules = """
    Output ONLY a JSON array (no prose, no fences) of task objects: \
    {"title": "<imperative, <=120 chars>", "description": "<markdown context, \
    include source details/links>", "labels": [1-4 short lowercase tags], \
    "taskKind": "code|writing|research|other", "estimate": \
    "minutes|hour|halfday|day+", "sourceKey": "<stable unique id, see below>", \
    "sourceURL": "<deep link if available, else null>"}. \
    Empty array [] if nothing found. If the app is NOT connected in Composio, \
    output the single line: NOT_CONNECTED.
    """

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
            One task per actionable item — ignore FYIs and resolved threads. \
            sourceKey = the message permalink or channel+ts; sourceURL = the \
            permalink. Quote the relevant message in the description. \(outputRules)
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
            event duration bucket. sourceKey = the calendar event id; \
            sourceURL = the event's htmlLink. \(outputRules)
            """
        }
    }
}
