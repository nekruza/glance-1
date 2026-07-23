import Foundation

/// Shared "what have I been working on" context: one digest per source
/// (Granola / Slack / Jira / GitHub) covering the last working day, fetched
/// through the same read-only Composio transport the inbox pulls use.
///
/// The whole point is to fetch ONCE and reuse: digests are cached on disk
/// with a TTL and in-flight requests are coalesced, so five prep-notes
/// generations in one morning cost four external fetches total, not twenty.
@MainActor
final class WorkContext {

    enum Source: String, CaseIterable, Codable {
        case granola, slack, jira, github

        var displayName: String {
            switch self {
            case .granola: return "Granola"
            case .slack: return "Slack"
            case .jira: return "Jira"
            case .github: return "GitHub"
            }
        }
    }

    struct Digest: Codable {
        var source: Source
        var text: String
        var fetchedAt: Date
    }

    /// How long a digest stays fresh. Within one working session the world
    /// doesn't change enough to justify re-hitting four APIs per meeting.
    static let ttl: TimeInterval = 45 * 60

    private let ingest: ComposioIngest
    /// Concurrent — digest fetches for different sources run in parallel
    /// (ComposioIngest's own pull queue is serial by design).
    private let fetchQueue = DispatchQueue(label: "com.h57q3wq0c.glance.workcontext",
                                           attributes: .concurrent)
    private var cache: [Source: Digest] = [:]
    /// Coalesce concurrent requests for the same source into one fetch.
    private var inFlight: [Source: [(String?) -> Void]] = [:]
    private let cacheURL: URL

    init(ingest: ComposioIngest) {
        self.ingest = ingest
        cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Glance/work-context.json")
        loadCache()
    }

    // MARK: - Public API

    /// Fetch (or reuse) digests for all sources; completes on main with
    /// whatever succeeded — a missing/unconnected source is simply absent.
    func digests(_ sources: [Source] = Source.allCases,
                 completion: @escaping ([Source: String]) -> Void) {
        var results: [Source: String] = [:]
        let group = DispatchGroup()
        for source in sources {
            group.enter()
            digest(source) { text in
                if let text { results[source] = text }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(results) }
    }

    /// One source: cache hit within TTL, else fetch and store. An empty cached
    /// text is a negative hit (source answered NOT_CONNECTED) — report "no
    /// digest" without paying for another fetch.
    func digest(_ source: Source, completion: @escaping (String?) -> Void) {
        if let hit = cache[source], Date().timeIntervalSince(hit.fetchedAt) < Self.ttl {
            completion(hit.text.isEmpty ? nil : hit.text)
            return
        }
        // Someone is already fetching this source — piggyback.
        if inFlight[source] != nil {
            inFlight[source]?.append(completion)
            return
        }
        inFlight[source] = [completion]
        ingest.runReadOnly(prompt: Self.prompt(for: source), on: fetchQueue) { [weak self] text, _ in
            guard let self else { return }
            let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            // FETCH_FAILED is transient: unusable now, but not cached, so the
            // next request retries.
            let usable: String? = (cleaned?.isEmpty == false && cleaned != "NOT_CONNECTED"
                                   && cleaned?.hasPrefix("FETCH_FAILED") != true)
                ? cleaned : nil
            if let usable {
                self.cache[source] = Digest(source: source, text: usable, fetchedAt: Date())
                self.saveCache()
            } else if cleaned == "NOT_CONNECTED" {
                // Negative-cache the explicit not-connected answer (empty text)
                // so a dead source doesn't cost a fresh subprocess on every
                // prep within the TTL. Transient failures (nil/error) are NOT
                // cached — they should retry on the next request.
                self.cache[source] = Digest(source: source, text: "", fetchedAt: Date())
                self.saveCache()
            }
            let waiters = self.inFlight.removeValue(forKey: source) ?? []
            for waiter in waiters { waiter(usable) }
        }
    }

    /// Freshness line for UI ("Slack 12m ago · Jira 12m ago").
    func freshness() -> String? {
        let parts = Source.allCases.compactMap { s -> String? in
            guard let d = cache[s], !d.text.isEmpty else { return nil }
            let mins = max(0, Int(Date().timeIntervalSince(d.fetchedAt) / 60))
            return "\(s.displayName) \(mins)m"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Prompts

    /// "Last working day" — yesterday, skipping back over weekends.
    static func lastWorkingDay(from now: Date = Date(),
                               calendar: Calendar = .current) -> Date {
        var d = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        while calendar.isDateInWeekend(d) {
            d = calendar.date(byAdding: .day, value: -1, to: d) ?? d
        }
        return d
    }

    private static func prompt(for source: Source) -> String {
        let since = lastWorkingDay()
            .formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        let header = """
        Using the composio tools, build a digest of MY activity since \
        \(since) (my last working day) up to now. \(ComposioIngest.readOnlyRules)
        """
        let footer = """
        Output ONLY markdown (no fences wrapping the output, no preamble): \
        5-15 terse bullets, most important first, max ~350 words. Every bullet \
        must be grounded in fetched data — no filler, no speculation. If the \
        app is NOT connected in Composio, output the single line: NOT_CONNECTED. \
        If fetching fails for any other reason (errors, timeouts, blocked \
        requests), output the single line: FETCH_FAILED — no explanation, no \
        questions, nothing else. Never answer with meta-commentary about the \
        fetch itself; the output is consumed as work context by another model.
        """
        switch source {
        case .granola:
            return """
            \(header)
            From Granola: my meetings in that window — for each: name, key \
            decisions, and action items. Flag an item **mine** ONLY when the \
            transcript explicitly assigns it to me by name — never because I \
            spoke about it or seem the likely owner; when ownership is \
            ambiguous, name whoever raised it instead. Teammates' updates are \
            THEIR work: keep the person's name attached to every update.
            \(footer)
            """
        case .slack:
            return """
            \(header)
            From Slack: threads where I was active or mentioned, and DMs — \
            what was discussed, what's still open/waiting on me or on others.
            \(footer)
            """
        case .jira:
            return """
            \(header)
            From Jira: issues I transitioned, commented on, or was assigned in \
            that window, plus my currently in-progress issues — key + summary \
            + status.
            \(footer)
            """
        case .github:
            return """
            \(header)
            From GitHub: my commits, PRs opened/merged/reviewed, and review \
            comments in that window — repo, title, state.
            \(footer)
            """
        }
    }

    // MARK: - Disk cache (survives app restarts within the TTL)

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let digests = try? JSONDecoder.glance.decode([Digest].self, from: data) else { return }
        for d in digests { cache[d.source] = d }
    }

    private func saveCache() {
        let digests = Array(cache.values)
        if let data = try? JSONEncoder.glance.encode(digests) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
