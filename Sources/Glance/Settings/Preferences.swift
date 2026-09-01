import Foundation
import Combine
import SwiftUI

/// User settings (FR17 hotkey, FR18 launch-at-login). FR19: nothing else in v1.
/// Backed by UserDefaults; observable so Settings UI and HotkeyManager react.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Keys {
        static let hotkeyKeyCode = "hotkey.keyCode"
        static let hotkeyModifiers = "hotkey.modifiers"
        static let overlayOpacity = "overlay.opacity"
        static let accentHex = "overlay.accentHex"
        static let taskHotkeyKeyCode = "taskHotkey.keyCode"
        static let taskHotkeyModifiers = "taskHotkey.modifiers"
        static let repos = "tasks.repos"
        static let agents = "tasks.agents"
        static let autoPlanApprove = "tasks.autoPlanApprove"
        static let composioURL = "composio.url"
        static let composioKey = "composio.key"
        static let enabledSources = "tasks.enabledSources"
        static let pullLastRuns = "tasks.pullLastRuns"
        static let knownApps = "tasks.knownApps"
        static let schedEnabled = "sched.enabled"
        static let schedSource = "sched.source"
        static let schedMode = "sched.mode"
        static let schedDailyMinutes = "sched.dailyMinutes"
        static let schedLastRun = "sched.lastRun"
        static let prepAutopilot = "prep.autopilotEnabled"
        static let prepLeadMinutes = "prep.leadMinutes"
        static let briefingEnabled = "briefing.enabled"
        static let briefingMinutes = "briefing.minutes"
        static let briefingLastRun = "briefing.lastRun"
        static let briefingMD = "briefing.md"
        static let briefingGeneratedAt = "briefing.generatedAt"
        static let autoTriage = "tasks.autoTriageEnabled"
        static let draftAutopilot = "tasks.draftAutopilotEnabled"
        static let completionSound = "tasks.completionSound"
        static let completionSoundName = "tasks.completionSoundName"
        static let confetti = "tasks.confetti"
        static let askBackend = "ask.backend"
        static let onboardingCompleted = "onboarding.completed"
    }

    enum ScheduleMode: String, CaseIterable {
        case hourly = "Every hour"
        case every4h = "Every 4 hours"
        case daily = "Daily at…"
    }

    /// Default dark-tint opacity of the overlay background.
    static let defaultOverlayOpacity: Double = 0.7

    /// Default accent — mint green (DS light design). Existing installs keep
    /// their saved color until Reset.
    static let defaultAccentHex = "66E194"

    private let defaults = UserDefaults.standard

    @Published var hotkey: KeyCombo {
        didSet {
            defaults.set(Int(hotkey.keyCode), forKey: Keys.hotkeyKeyCode)
            defaults.set(Int(hotkey.modifiers), forKey: Keys.hotkeyModifiers)
        }
    }

    /// Task-board hotkey (V2 FR20). Default ⌥T.
    @Published var taskHotkey: KeyCombo {
        didSet {
            defaults.set(Int(taskHotkey.keyCode), forKey: Keys.taskHotkeyKeyCode)
            defaults.set(Int(taskHotkey.modifiers), forKey: Keys.taskHotkeyModifiers)
        }
    }

    /// First-run tour: set once the user finishes or closes the welcome
    /// window. Not @Published — nothing observes it live.
    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Keys.onboardingCompleted) }
        set { defaults.set(newValue, forKey: Keys.onboardingCompleted) }
    }

    /// Repo registry (V2 FR60) — used by enrichment mapping + workspace picker.
    @Published var repos: [RepoEntry] {
        didSet {
            if let data = try? JSONEncoder().encode(repos) {
                defaults.set(data, forKey: Keys.repos)
            }
        }
    }

    /// Agent roster (built-ins seeded on first launch + user customs).
    @Published var agents: [AgentProfile] {
        didSet {
            if let data = try? JSONEncoder().encode(agents) {
                defaults.set(data, forKey: Keys.agents)
            }
        }
    }

    func agent(_ id: UUID?) -> AgentProfile? {
        guard let id else { return nil }
        return agents.first { $0.id == id }
    }

    /// §6 A7: auto-approve plans for small non-code tasks with no boundary
    /// actions. Code tasks are always gated regardless.
    @Published var autoPlanApprove: Bool {
        didSet { defaults.set(autoPlanApprove, forKey: Keys.autoPlanApprove) }
    }

    /// Composio MCP endpoint + API key (read-only ingestion for Jira/Slack/
    /// Granola). Stored in defaults — single-user personal tool; NFR11's
    /// "no external credentials" posture is knowingly relaxed here.
    @Published var composioURL: String {
        didSet { defaults.set(composioURL, forKey: Keys.composioURL) }
    }
    @Published var composioKey: String {
        didSet { defaults.set(composioKey, forKey: Keys.composioKey) }
    }

    /// Which ingest sources Glance fetches from — the single gate for manual
    /// `pullAll`, the pill menu, and scheduled "All" pulls. Holds
    /// `ComposioIngest.FetchTarget.key` values: built-in `Source` rawValues
    /// ("Jira") plus "app:<slug>" for generic connected apps. Defaults to the
    /// original four; everything else is opt-in.
    @Published var enabledSources: Set<String> {
        didSet { defaults.set(Array(enabledSources), forKey: Keys.enabledSources) }
    }

    /// Connected Composio apps with no curated fetch source, slug → display
    /// name. Cached from the last connections listing so the pull menu can
    /// offer them without a network round-trip.
    @Published var knownApps: [String: String] {
        didSet { defaults.set(knownApps, forKey: Keys.knownApps) }
    }

    func isFetchEnabled(_ target: ComposioIngest.FetchTarget) -> Bool {
        enabledSources.contains(target.key)
    }
    func setFetch(_ target: ComposioIngest.FetchTarget, _ on: Bool) {
        if on { enabledSources.insert(target.key) }
        else { enabledSources.remove(target.key) }
    }
    func isFetchEnabled(_ source: ComposioIngest.Source) -> Bool {
        isFetchEnabled(.builtin(source))
    }
    func setFetch(_ source: ComposioIngest.Source, _ on: Bool) {
        setFetch(.builtin(source), on)
    }

    /// Per-target last successful pull, keyed by `FetchTarget.key` — lets the
    /// fetch prompts ask for "updated since my last pull" instead of a fixed
    /// 30-day window (the dominant token cost of an MCP pull session is the
    /// tool results, so narrow windows are the big saver). Plain defaults
    /// dict, not @Published — no UI observes it.
    func pullLastRun(_ targetKey: String) -> Date? {
        (defaults.dictionary(forKey: Keys.pullLastRuns)?[targetKey]) as? Date
    }
    func setPullLastRun(_ targetKey: String, _ date: Date) {
        var d = defaults.dictionary(forKey: Keys.pullLastRuns) ?? [:]
        d[targetKey] = date
        defaults.set(d, forKey: Keys.pullLastRuns)
    }

    /// Every fetch target the user has toggled on: enabled built-ins first
    /// (declaration order), then enabled generic apps alphabetically.
    var enabledFetchTargets: [ComposioIngest.FetchTarget] {
        let builtins = ComposioIngest.Source.allCases
            .map { ComposioIngest.FetchTarget.builtin($0) }
            .filter(isFetchEnabled)
        let apps = knownApps.sorted { $0.value < $1.value }
            .map { ComposioIngest.FetchTarget.app(slug: $0.key, name: $0.value) }
            .filter(isFetchEnabled)
        return builtins + apps
    }

    /// Scheduled pulls: run a Composio pull automatically on a cadence.
    @Published var schedEnabled: Bool {
        didSet { defaults.set(schedEnabled, forKey: Keys.schedEnabled) }
    }
    /// "All" or a ComposioIngest.Source rawValue.
    @Published var schedSource: String {
        didSet { defaults.set(schedSource, forKey: Keys.schedSource) }
    }
    @Published var schedMode: ScheduleMode {
        didSet { defaults.set(schedMode.rawValue, forKey: Keys.schedMode) }
    }
    /// Minutes since midnight for the daily mode (default 09:00).
    @Published var schedDailyMinutes: Int {
        didSet { defaults.set(schedDailyMinutes, forKey: Keys.schedDailyMinutes) }
    }
    var schedLastRun: Date? {
        get { defaults.object(forKey: Keys.schedLastRun) as? Date }
        set { defaults.set(newValue, forKey: Keys.schedLastRun) }
    }

    /// Meeting prep autopilot: auto-generate prep notes shortly before each
    /// calendar meeting and notify when they're ready.
    @Published var prepAutopilotEnabled: Bool {
        didSet { defaults.set(prepAutopilotEnabled, forKey: Keys.prepAutopilot) }
    }
    /// How many minutes before the meeting start prep kicks off.
    @Published var prepLeadMinutes: Int {
        didSet { defaults.set(prepLeadMinutes, forKey: Keys.prepLeadMinutes) }
    }

    /// Morning briefing (A1): each workday at `briefingMinutes`, compose a
    /// one-page briefing from local board data and notify.
    @Published var briefingEnabled: Bool {
        didSet { defaults.set(briefingEnabled, forKey: Keys.briefingEnabled) }
    }
    /// Minutes since midnight for the briefing time (default 09:00).
    @Published var briefingMinutes: Int {
        didSet { defaults.set(briefingMinutes, forKey: Keys.briefingMinutes) }
    }
    var briefingLastRun: Date? {
        get { defaults.object(forKey: Keys.briefingLastRun) as? Date }
        set { defaults.set(newValue, forKey: Keys.briefingLastRun) }
    }
    /// Latest briefing markdown + timestamp — persisted so it survives
    /// relaunch (the panel shows the last one until the next lands).
    @Published var briefingMD: String {
        didSet { defaults.set(briefingMD, forKey: Keys.briefingMD) }
    }
    @Published var briefingGeneratedAt: Date? {
        didSet { defaults.set(briefingGeneratedAt, forKey: Keys.briefingGeneratedAt) }
    }

    /// Auto-triage: after a pull, AI enriches each freshly-landed inbox item,
    /// filling only the fields the pull left empty (user/pull values win).
    @Published var autoTriageEnabled: Bool {
        didSet { defaults.set(autoTriageEnabled, forKey: Keys.autoTriage) }
    }
    /// Draft autopilot: generate the outbound draft for accepted Slack/Jira
    /// tasks without one and park them in the Review queue. Sending always
    /// stays behind an explicit per-item approval.
    @Published var draftAutopilotEnabled: Bool {
        didSet { defaults.set(draftAutopilotEnabled, forKey: Keys.draftAutopilot) }
    }

    /// Play a system sound when a task is completed by hand.
    @Published var completionSoundEnabled: Bool {
        didSet { defaults.set(completionSoundEnabled, forKey: Keys.completionSound) }
    }
    /// NSSound system-sound name for the completion chime.
    @Published var completionSoundName: String {
        didSet { defaults.set(completionSoundName, forKey: Keys.completionSoundName) }
    }
    /// Confetti burst on completion (auto-suppressed by Reduce Motion).
    @Published var confettiEnabled: Bool {
        didSet { defaults.set(confettiEnabled, forKey: Keys.confetti) }
    }

    /// Preferred local CLI backend for ask-overlay requests.
    @Published var askBackend: AskBackendKind {
        didSet { defaults.set(askBackend.rawValue, forKey: Keys.askBackend) }
    }

    /// Overlay background opacity (0.2 barely-there … 1.0 solid).
    @Published var overlayOpacity: Double {
        didSet { defaults.set(overlayOpacity, forKey: Keys.overlayOpacity) }
    }

    /// Accent color as an RRGGBB hex string (drives Theme.accent everywhere).
    @Published var accentHex: String {
        didSet { defaults.set(accentHex, forKey: Keys.accentHex) }
    }

    var accentColor: Color {
        get { Color(hexRGB: accentHex) ?? Color(hexRGB: Self.defaultAccentHex)! }
        set { accentHex = newValue.hexRGB ?? Self.defaultAccentHex }
    }

    private init() {
        if defaults.object(forKey: Keys.hotkeyKeyCode) != nil {
            let code = UInt32(defaults.integer(forKey: Keys.hotkeyKeyCode))
            let mods = UInt32(defaults.integer(forKey: Keys.hotkeyModifiers))
            let combo = KeyCombo(keyCode: code, modifiers: mods)
            hotkey = combo.isValid ? combo : .defaultCombo
        } else {
            hotkey = .defaultCombo
        }
        if defaults.object(forKey: Keys.overlayOpacity) != nil {
            overlayOpacity = min(max(defaults.double(forKey: Keys.overlayOpacity), 0.2), 1.0)
        } else {
            overlayOpacity = Self.defaultOverlayOpacity
        }
        accentHex = defaults.string(forKey: Keys.accentHex) ?? Self.defaultAccentHex
        if defaults.object(forKey: Keys.taskHotkeyKeyCode) != nil {
            let code = UInt32(defaults.integer(forKey: Keys.taskHotkeyKeyCode))
            let mods = UInt32(defaults.integer(forKey: Keys.taskHotkeyModifiers))
            let combo = KeyCombo(keyCode: code, modifiers: mods)
            taskHotkey = combo.isValid ? combo : .defaultTaskCombo
        } else {
            taskHotkey = .defaultTaskCombo
        }
        if let data = defaults.data(forKey: Keys.repos),
           let decoded = try? JSONDecoder().decode([RepoEntry].self, from: data) {
            repos = decoded
        } else {
            repos = []
        }
        autoPlanApprove = defaults.object(forKey: Keys.autoPlanApprove) == nil
            ? true : defaults.bool(forKey: Keys.autoPlanApprove)
        if let data = defaults.data(forKey: Keys.agents),
           var decoded = try? JSONDecoder().decode([AgentProfile].self, from: data),
           !decoded.isEmpty {
            // Migrate pre-emoji profiles (icons were SF-Symbol names).
            var migrated = false
            for i in decoded.indices where decoded[i].hasLegacyIcon {
                decoded[i].icon = AgentProfile.emojiFor(legacyIcon: decoded[i].icon,
                                                        name: decoded[i].name)
                migrated = true
            }
            // Backfill humanName on built-ins persisted before this field existed.
            for i in decoded.indices where decoded[i].isBuiltIn && decoded[i].humanName == nil {
                if let shipped = AgentProfile.builtIns.first(where: { $0.id == decoded[i].id }) {
                    decoded[i].humanName = shipped.humanName
                    migrated = true
                }
            }
            // Add any built-ins shipped after this install's first launch (e.g. Analyst).
            let knownIds = Set(decoded.map(\.id))
            for shipped in AgentProfile.builtIns where !knownIds.contains(shipped.id) {
                decoded.append(shipped)
                migrated = true
            }
            agents = decoded
            if migrated, let data = try? JSONEncoder().encode(decoded) {
                defaults.set(data, forKey: Keys.agents)
            }
        } else {
            agents = AgentProfile.builtIns
            // didSet doesn't fire during init — persist the seed explicitly.
            if let data = try? JSONEncoder().encode(AgentProfile.builtIns) {
                defaults.set(data, forKey: Keys.agents)
            }
        }
        composioURL = defaults.string(forKey: Keys.composioURL) ?? "https://connect.composio.dev/mcp"
        composioKey = defaults.string(forKey: Keys.composioKey) ?? ""
        if let arr = defaults.array(forKey: Keys.enabledSources) as? [String] {
            enabledSources = Set(arr)
        } else {
            enabledSources = Set(ComposioIngest.Source.defaultEnabled.map(\.rawValue))
        }
        knownApps = defaults.dictionary(forKey: Keys.knownApps) as? [String: String] ?? [:]
        schedEnabled = defaults.bool(forKey: Keys.schedEnabled)
        schedSource = defaults.string(forKey: Keys.schedSource) ?? "All"
        schedMode = ScheduleMode(rawValue: defaults.string(forKey: Keys.schedMode) ?? "") ?? .daily
        schedDailyMinutes = defaults.object(forKey: Keys.schedDailyMinutes) == nil
            ? 9 * 60 : defaults.integer(forKey: Keys.schedDailyMinutes)
        prepAutopilotEnabled = defaults.object(forKey: Keys.prepAutopilot) == nil
            ? true : defaults.bool(forKey: Keys.prepAutopilot)
        prepLeadMinutes = defaults.object(forKey: Keys.prepLeadMinutes) == nil
            ? 20 : max(5, defaults.integer(forKey: Keys.prepLeadMinutes))
        briefingEnabled = defaults.object(forKey: Keys.briefingEnabled) == nil
            ? true : defaults.bool(forKey: Keys.briefingEnabled)
        briefingMinutes = defaults.object(forKey: Keys.briefingMinutes) == nil
            ? 9 * 60 : defaults.integer(forKey: Keys.briefingMinutes)
        briefingMD = defaults.string(forKey: Keys.briefingMD) ?? ""
        briefingGeneratedAt = defaults.object(forKey: Keys.briefingGeneratedAt) as? Date
        autoTriageEnabled = defaults.object(forKey: Keys.autoTriage) == nil
            ? true : defaults.bool(forKey: Keys.autoTriage)
        draftAutopilotEnabled = defaults.object(forKey: Keys.draftAutopilot) == nil
            ? true : defaults.bool(forKey: Keys.draftAutopilot)
        completionSoundEnabled = defaults.object(forKey: Keys.completionSound) == nil
            ? true : defaults.bool(forKey: Keys.completionSound)
        completionSoundName = defaults.string(forKey: Keys.completionSoundName) ?? "Glass"
        confettiEnabled = defaults.object(forKey: Keys.confetti) == nil
            ? true : defaults.bool(forKey: Keys.confetti)
        askBackend = AskBackendKind(rawValue: defaults.string(forKey: Keys.askBackend) ?? "")
            ?? .claude
    }
}

// MARK: - Hex color helpers

extension Color {
    /// "RRGGBB" (with or without leading #) → Color, sRGB.
    init?(hexRGB: String) {
        var s = hexRGB.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255,
                  green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255)
    }

    /// Color → "RRGGBB" (sRGB, alpha dropped).
    var hexRGB: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}
