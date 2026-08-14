import SwiftUI

/// In-window settings for the Tasks app window: left sidebar sections, right
/// content — light DS design (the system Settings window remains as a
/// fallback when the task system is unavailable).
struct TaskSettingsView: View {

    static let askBackendRowTitle = "AI provider"

    enum Section: String, CaseIterable {
        case general = "General"
        case appearance = "Appearance"
        case ai = "AI & Runs"
        case agents = "Agents"
        case repos = "Repos"
        case connections = "Connections"
        case schedule = "Schedule"
        case activity = "Activity"
        case about = "About"

        var icon: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .appearance: return "sun.max"
            case .ai: return "cpu"
            case .agents: return "person.2"
            case .repos: return "folder"
            case .connections: return "link"
            case .schedule: return "clock.arrow.2.circlepath"
            case .activity: return "clock"
            case .about: return "info.circle"
            }
        }
    }

    @ObservedObject private var prefs = Preferences.shared
    @State private var section: Section = .general
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var askBackendStatus: AskBackendStatus = .notConnected
    @ObservedObject private var backendTest: BackendTestSession

    @State private var connections: [ComposioIngest.Connection] = []
    @State private var connectionsLoading = false
    @State private var connectionsError: String?
    @State private var connectionsCheckedAt: Date?
    @State private var keyDraft = ""

    @ObservedObject var session: TaskBoardSession
    var onClose: () -> Void

    init(session: TaskBoardSession, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
        _backendTest = ObservedObject(wrappedValue: session.backendTestSession)
    }

    private enum AskBackendStatus {
        case ok(version: String)
        case notConnected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(DS.divider)
            HStack(spacing: 0) {
                sidebar
                Divider().overlay(DS.divider)
                ScrollView {
                    content
                        .padding(DS.Space.lg)
                        // Full-width, responsive: content fills the window (was
                        // capped at 560). The connectors grid + adaptive columns
                        // reflow to whatever width is available.
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(DS.bg)
            }
            .frame(maxHeight: .infinity)
        }
        .onAppear { rescanAskBackend() }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: DS.Space.xs) {
            BackButton(label: "Back", action: onClose)
            Text("Settings")
                .font(DS.Typo.headline)
                .foregroundStyle(DS.textPrimary)
            Spacer()
        }
        .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.allCases, id: \.self) { s in
                let selected = section == s
                Hover { hovering in
                    Button(action: { section = s }) {
                        HStack(spacing: DS.Space.xs) {
                            Image(systemName: s.icon)
                                .font(DS.Typo.caption)
                                .foregroundStyle(selected ? DS.accentText : DS.textSecondary)
                                .frame(width: 16)
                            Text(s.rawValue)
                                .font(DS.Typo.label)
                                .foregroundStyle(selected ? DS.textPrimary : DS.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, DS.Space.xs + 2).padding(.vertical, DS.Space.xxs + 3)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.small)
                            .fill(selected ? DS.accentSoft : (hovering ? DS.surfaceHover : .clear)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(DS.Space.xs + 2)
        .frame(width: 200)
        .background(DS.surface)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch section {
        case .general: generalSection
        case .appearance: appearanceSection
        case .ai: aiSection
        case .agents: agentsSection
        case .repos: reposSection
        case .connections: connectionsSection
        case .schedule: scheduleSection
        case .activity: activitySection
        case .about: aboutSection
        }
    }

    // MARK: - Activity (FR58–59)

    private var activitySection: some View {
        let events = session.activityFeed()
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Text("Every gate decision and run event, most recent first.")
                    .font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
                Spacer()
                Button(action: {
                    if let url = session.exportBoard() { NSWorkspace.shared.open(url) }
                }) {
                    Label("Export board + log", systemImage: "square.and.arrow.up")
                        .font(DS.Typo.label)
                }
                .controlSize(.small)
            }
            Divider().overlay(DS.divider)

            if events.isEmpty {
                VStack(spacing: DS.Space.xs) {
                    Image(systemName: "clock")
                        .font(.system(size: 28))
                        .foregroundStyle(DS.textTertiary)
                    Text("No activity yet")
                        .font(DS.Typo.headline)
                        .foregroundStyle(DS.textSecondary)
                    Text("Run a task and every gate decision lands here.")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(DS.Space.xl)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(events) { e in
                        HStack(alignment: .top, spacing: DS.Space.xs) {
                            Image(systemName: e.icon)
                                .font(DS.Typo.caption)
                                .foregroundStyle(DS.textSecondary)
                                .frame(width: 16)
                            Text(e.text)
                                .font(DS.Typo.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(e.at.formatted(date: .abbreviated, time: .shortened))
                                .font(DS.Typo.mono)
                                .foregroundStyle(DS.textTertiary)
                        }
                        .padding(.vertical, DS.Space.xxs + 2)
                        Divider().overlay(DS.divider)
                    }
                }
            }
        }
    }

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            apiKeyHeader
            Divider().overlay(DS.divider)

            HStack(spacing: DS.Space.xs) {
                overline("Connected apps")
                Spacer()
                Button(action: refreshConnections) {
                    HStack(spacing: DS.Space.xxs) {
                        if connectionsLoading { ProgressView().controlSize(.mini) }
                        Text(connectionsLoading ? "Checking…" : "Refresh")
                    }
                }
                .buttonStyle(DSSecondaryButtonStyle()).disabled(connectionsLoading)
                Button("Open dashboard") {
                    NSWorkspace.shared.open(URL(string: "https://dashboard.composio.dev/")!)
                }
                .buttonStyle(DSPrimaryButtonStyle())
            }

            if let err = connectionsError {
                Text(err).font(DS.Typo.caption).foregroundStyle(DS.danger)
            }

            let sorted = connections.sorted { a, b in
                if a.isActive != b.isActive { return a.isActive }
                return a.app.localizedCaseInsensitiveCompare(b.app) == .orderedAscending
            }
            if sorted.isEmpty {
                Text(connectionsEmptyMessage)
                    .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: DS.Space.sm)],
                          alignment: .leading, spacing: DS.Space.sm) {
                    ForEach(sorted) { c in connectionCard(c) }
                }
            }

            Text("Every connected app has a switch — toggled-on apps are the sources Glance pulls tasks from and show in the board's pull menu. Connect more apps in the Composio dashboard.")
                .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
        }
        // Auto-load connections the first time this page opens.
        .onAppear {
            if connectionsCheckedAt == nil && !connectionsLoading { refreshConnections() }
        }
    }

    private var connectionsEmptyMessage: String {
        if connectionsLoading { return "Checking your connected apps…" }
        if connectionsCheckedAt == nil { return "Loading your connected apps…" }
        return "No connected apps yet. Open the Composio dashboard to connect one, then Refresh."
    }

    // MARK: API key header (matches the reference: masked-Saved pill + Save/Clear)

    private var apiKeyHeader: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.xs) {
                Text("Composio API Key").font(DS.Typo.headline).foregroundStyle(DS.textPrimary)
                if let masked = maskedKey {
                    pill(masked, DS.success, soft: DS.successSoft)
                } else {
                    pill("Not set", DS.warning, soft: DS.warningSoft)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(string: "https://dashboard.composio.dev/developers")!)
                } label: {
                    HStack(spacing: 3) {
                        Text("Get API Key")
                        Image(systemName: "arrow.up.right")
                    }
                    .font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
                }
                .buttonStyle(.plain).pointerCursor()
            }

            HStack(spacing: DS.Space.xs) {
                SecureField("Paste a new key to replace the saved one", text: $keyDraft)
                    .textFieldStyle(.plain).font(DS.Typo.body)
                    .padding(DS.Space.xs)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.surface))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.small)
                        .strokeBorder(DS.border, lineWidth: 1))
                Button("Save key") { saveKey() }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Clear") { prefs.composioKey = "" }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .disabled(prefs.composioKey.isEmpty)
            }

            Text("Your key is stored locally and used for read-only pulls. Paste a new key to replace it, or Clear to remove.")
                .font(DS.Typo.caption).foregroundStyle(DS.textSecondary)

            HStack(spacing: DS.Space.xs) {
                Text("MCP URL").font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
                TextField("https://…", text: $prefs.composioURL)
                    .textFieldStyle(.roundedBorder).font(DS.Typo.caption).frame(maxWidth: 320)
            }
        }
    }

    // MARK: Connected-app card

    @ViewBuilder private func connectionCard(_ c: ComposioIngest.Connection) -> some View {
        let source = fetchSource(matching: c.app)
        let match = catalogEntry(for: c.app)
        let name = match?.name ?? c.app.capitalized
        let slug = match?.slug ?? c.app.lowercased()

        HStack(alignment: .top, spacing: DS.Space.xs) {
            Text(monogram(name))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: DS.Radius.small)
                    .fill(tileColor(slug)))

            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(DS.Typo.body).fontWeight(.semibold)
                    .foregroundStyle(DS.textPrimary).lineLimit(1)
                if let category = match?.category {
                    Text(category).font(DS.Typo.caption)
                        .foregroundStyle(DS.textSecondary).lineLimit(1)
                }
                statusPill(for: c)
            }
            Spacer(minLength: DS.Space.xxs)

            let target: ComposioIngest.FetchTarget = source.map { .builtin($0) }
                ?? .app(slug: normalizedApp(c.app), name: name)
            Toggle("", isOn: Binding(
                get: { prefs.isFetchEnabled(target) },
                set: { prefs.setFetch(target, $0) }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium)
            .strokeBorder(DS.border, lineWidth: 1))
    }

    // MARK: Connected-app helpers

    /// Matching lives on `ComposioIngest.Source` now (the pull pipeline needs
    /// it too); these stay as local shorthands.
    private func normalizedApp(_ app: String) -> String {
        ComposioIngest.Source.normalizedApp(app)
    }

    private func fetchSource(matching app: String) -> ComposioIngest.Source? {
        ComposioIngest.Source.match(app: app)
    }

    /// Catalog entry for a connection, matched precisely: exact slug first, then
    /// the canonical entry for a recognised fetch source. Avoids the substring
    /// false-positive where a Google Calendar connection matched Cal.com ("cal").
    private func catalogEntry(for app: String) -> ComposioCatalog.App? {
        let a = normalizedApp(app)
        if let exact = ComposioCatalog.all.first(where: { $0.slug == a }) { return exact }
        if let source = fetchSource(matching: a) {
            let canonical: String
            switch source {
            case .jira:     canonical = "jira"
            case .slack:    canonical = "slack"
            case .granola:  canonical = "granola"
            case .calendar: canonical = "googlecalendar"
            case .github:   canonical = "github"
            case .gmail:    canonical = "gmail"
            }
            return ComposioCatalog.all.first { $0.slug == canonical }
        }
        return nil
    }

    @ViewBuilder private func statusPill(for conn: ComposioIngest.Connection?) -> some View {
        if connectionsCheckedAt == nil {
            EmptyView()
        } else if let conn {
            if conn.isActive {
                pill("Connected", DS.success, soft: DS.successSoft)
            } else {
                pill(conn.status.capitalized, DS.warning, soft: DS.warningSoft)
            }
        } else {
            pill("Not linked", DS.textTertiary, soft: DS.surfaceHover)
        }
    }

    private var maskedKey: String? {
        let k = prefs.composioKey
        guard !k.isEmpty else { return nil }
        return "Saved · ••••" + String(k.suffix(4))
    }

    private func saveKey() {
        let k = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        prefs.composioKey = k
        keyDraft = ""
    }

    /// 1–2 uppercase initials for the icon tile (no brand-logo assets shipped).
    private func monogram(_ name: String) -> String {
        let words = name.split { $0 == " " || $0 == "." || $0 == "/" }.filter { !$0.isEmpty }
        if words.count >= 2, let a = words[0].first, let b = words[1].first {
            return (String(a) + String(b)).uppercased()
        }
        return String(name.prefix(1)).uppercased()
    }

    /// Deterministic tile color from the slug (stable across launches).
    private static let tilePalette: [Color] = [
        "4C6EF5", "12B886", "E8590C", "BE4BDB", "1098AD",
        "7048E8", "E64980", "2B8A3E", "F08C00", "0CA678",
    ].map { Color(hexRGB: $0)! }

    private func tileColor(_ slug: String) -> Color {
        let sum = slug.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Self.tilePalette[sum % Self.tilePalette.count]
    }

    private func refreshConnections() {
        connectionsLoading = true
        connectionsError = nil
        session.listConnections { list, error in
            connectionsLoading = false
            connectionsCheckedAt = Date()
            if let list {
                connections = list.sorted { $0.app < $1.app }
                syncKnownApps(from: list)
            } else {
                connectionsError = error
            }
        }
    }

    /// Cache active connections with no curated source so the canvas pull
    /// menu can offer them (slug → display name). Prune stale entries and
    /// their enabled-toggle keys when an app is disconnected.
    private func syncKnownApps(from list: [ComposioIngest.Connection]) {
        var apps: [String: String] = [:]
        for c in list where c.isActive && fetchSource(matching: c.app) == nil {
            let slug = normalizedApp(c.app)
            apps[slug] = catalogEntry(for: c.app)?.name ?? c.app.capitalized
        }
        let removed = Set(prefs.knownApps.keys).subtracting(apps.keys)
        for slug in removed { prefs.enabledSources.remove("app:\(slug)") }
        prefs.knownApps = apps
    }


    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Ask overlay hotkey", "Summon the ask-anything overlay") {
                HotkeyRecorder(combo: $prefs.hotkey).frame(width: 140, height: 24)
            }
            Divider().overlay(DS.divider)
            row("Task board hotkey", "Summon this board") {
                HotkeyRecorder(combo: $prefs.taskHotkey).frame(width: 140, height: 24)
            }
            Divider().overlay(DS.divider)
            row("Launch at login", "Start in the menu bar when you sign in") {
                Toggle("", isOn: $launchAtLogin)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .onChange(of: launchAtLogin) { _, v in LaunchAtLogin.set(v) }
            }
            Divider().overlay(DS.divider)
            row("Completion sound", "A little chime when you check a task off") {
                HStack(spacing: DS.Space.xs) {
                    if prefs.completionSoundEnabled {
                        Picker("", selection: $prefs.completionSoundName) {
                            ForEach(CompletionSound.choices, id: \.self) { Text($0) }
                        }
                        .labelsHidden().controlSize(.small).frame(width: 90)
                        .onChange(of: prefs.completionSoundName) { _, name in
                            CompletionSound.play(named: name) // preview
                        }
                    }
                    Toggle("", isOn: $prefs.completionSoundEnabled)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            Divider().overlay(DS.divider)
            row("Confetti", "Celebrate completions on Todo (off automatically with Reduce Motion)") {
                Toggle("", isOn: $prefs.confettiEnabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Overlay opacity", "How solid the ask overlay background is") {
                HStack(spacing: DS.Space.xs) {
                    Slider(value: $prefs.overlayOpacity, in: 0.2...1.0).frame(width: 130)
                    Text("\(Int(prefs.overlayOpacity * 100))%")
                        .font(DS.Typo.mono)
                        .foregroundStyle(DS.textSecondary).frame(width: 32, alignment: .trailing)
                }
            }
            Divider().overlay(DS.divider)
            row("Accent color", "Buttons, badges and highlights") {
                HStack(spacing: DS.Space.xs) {
                    ColorPicker("", selection: $prefs.accentColor, supportsOpacity: false)
                        .labelsHidden()
                    Button("Reset") { prefs.accentHex = Preferences.defaultAccentHex }
                        .controlSize(.small)
                        .disabled(prefs.accentHex == Preferences.defaultAccentHex)
                }
            }
        }
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(Self.askBackendRowTitle, "Local CLI used for Ask, tasks, suggestions, meetings, and Composio") {
                Picker("", selection: $prefs.askBackend) {
                    ForEach(AskBackendKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                .onChange(of: prefs.askBackend) { _, _ in
                    backendTest.providerDidChange(to: prefs.askBackend)
                    connectionsLoading = false
                    connectionsError = nil
                    connectionsCheckedAt = nil
                    connections = []
                    rescanAskBackend()
                }
            }
            Divider().overlay(DS.divider)
            row(prefs.askBackend.displayName, askBackendSubtitle) {
                HStack(spacing: DS.Space.xs) {
                    if case .ok = askBackendStatus {
                        pill("Connected", DS.success, soft: DS.successSoft)
                    } else {
                        pill("Not connected", DS.warning, soft: DS.warningSoft)
                    }
                    Button(backendTest.isTesting ? "Testing…" : "Test") { runTest() }
                        .controlSize(.small)
                        .disabled(backendTest.isTesting)
                }
            }
            if let outcome = backendTest.outcome {
                Text(testResultText(outcome)).font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
                    .padding(.bottom, DS.Space.xs)
            }
            Divider().overlay(DS.divider)
            row("Auto-approve small plans",
                "Skip the plan gate for non-code tasks ≤1h with no external actions. Code always gated.") {
                Toggle("", isOn: $prefs.autoPlanApprove)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    // MARK: - Agents (moved to the dedicated AI Agents page)

    /// Agent creation/editing now lives on its own full-page surface
    /// (`AgentManagementView`). This section is a short signpost so the old
    /// Settings ▸ Agents entry still lands somewhere sensible.
    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("Agents have moved to their own page")
                .font(DS.Typo.body).foregroundStyle(DS.textPrimary)
            Text("Create, edit, and manage your AI agents on the dedicated AI Agents page — more room, a searchable roster, and a full editor.")
                .font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.xs + 2) {
                ForEach(prefs.agents.prefix(6)) { agent in
                    AgentAvatarView(agent: agent, size: 32)
                }
                if prefs.agents.count > 6 {
                    Text("+\(prefs.agents.count - 6)")
                        .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
                }
            }
            .padding(.vertical, DS.Space.xxs)
            Button(action: {
                session.showSettings = false
                session.showAgents = true
            }) {
                Label("Open AI Agents", systemImage: "person.2")
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .pointerCursor()
        }
    }

    private var reposSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("Where AI agents run code tasks — always in an isolated worktree, never your live checkout.")
                .font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
            if prefs.repos.isEmpty {
                Text("No repos yet — add one so code tasks have somewhere to run.")
                    .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
            }
            ForEach(prefs.repos) { repo in
                Hover { hovering in
                    HStack {
                        Image(systemName: "folder").font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
                        Text(repo.name).font(DS.Typo.label)
                        Text(repo.path).font(DS.Typo.mono)
                            .foregroundStyle(DS.textTertiary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(action: { prefs.repos.removeAll { $0.id == repo.id } }) {
                            Image(systemName: "minus.circle").font(DS.Typo.label)
                                .foregroundStyle(DS.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove repo")
                    }
                    .padding(.vertical, DS.Space.xxs + 1).padding(.horizontal, DS.Space.xs + 2)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.small)
                        .fill(hovering ? DS.surfaceHover : DS.bg))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.small)
                        .strokeBorder(DS.border, lineWidth: 1))
                }
            }
            Button("Add repo…") { addRepo() }.controlSize(.small)
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Scheduled pulls", "Fetch new work automatically into the Inbox") {
                Toggle("", isOn: $prefs.schedEnabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if prefs.schedEnabled {
                Divider().overlay(DS.divider)
                row("Schedule", "") {
                    HStack(spacing: DS.Space.xxs + 2) {
                        Picker("", selection: $prefs.schedSource) {
                            Text("All sources").tag("All")
                            ForEach(ComposioIngest.Source.allCases, id: \.rawValue) { s in
                                Text(s.rawValue).tag(s.rawValue)
                            }
                        }
                        .labelsHidden().controlSize(.small).frame(width: 105)
                        Picker("", selection: $prefs.schedMode) {
                            ForEach(Preferences.ScheduleMode.allCases, id: \.self) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .labelsHidden().controlSize(.small).frame(width: 120)
                        if prefs.schedMode == .daily {
                            DatePicker("", selection: dailyTimeBinding,
                                       displayedComponents: .hourAndMinute)
                                .labelsHidden().controlSize(.small)
                        }
                    }
                }
            }
            Divider().overlay(DS.divider)
            row("Morning briefing", "Each workday: what arrived overnight, what's in Review, today's meetings, and a suggested top 3") {
                Toggle("", isOn: $prefs.briefingEnabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if prefs.briefingEnabled {
                Divider().overlay(DS.divider)
                row("Briefing time", "") {
                    DatePicker("", selection: briefingTimeBinding,
                               displayedComponents: .hourAndMinute)
                        .labelsHidden().controlSize(.small)
                }
            }
            Divider().overlay(DS.divider)
            row("Meeting prep autopilot", "Write prep notes automatically before each meeting") {
                Toggle("", isOn: $prefs.prepAutopilotEnabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if prefs.prepAutopilotEnabled {
                Divider().overlay(DS.divider)
                row("Prep lead time", "How long before the meeting prep starts") {
                    Picker("", selection: $prefs.prepLeadMinutes) {
                        ForEach([10, 15, 20, 30, 45, 60], id: \.self) { m in
                            Text("\(m) min").tag(m)
                        }
                    }
                    .labelsHidden().controlSize(.small).frame(width: 90)
                }
            }
            Divider().overlay(DS.divider)
            row("Auto-triage new items", "AI fills kind, labels and description on freshly pulled inbox items") {
                Toggle("", isOn: $prefs.autoTriageEnabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Divider().overlay(DS.divider)
            row("Draft autopilot", "Draft Slack replies and Jira comments for accepted items — ready to review, never auto-sent") {
                Toggle("", isOn: $prefs.draftAutopilotEnabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("Glance v1.0").font(DS.Typo.title)
            Text("Personal AI assistant: Ask overlay, meeting transcription, and an AI task board — all running through your selected AI provider.")
                .font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
            Divider().overlay(DS.divider)
            Text("No API keys for model traffic — everything goes through your selected \(prefs.askBackend.displayName) and its auth. Task data stays in ~/Library/Application Support/Glance. The Composio key (Sources) is the one stored credential, used for read-only pulls.")
                .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
        }
    }

    // MARK: - Bits

    private func overline(_ text: String) -> some View {
        Text(text.uppercased())
            .font(DS.Typo.overline).tracking(0.8)
            .foregroundStyle(DS.textTertiary)
    }

    private func row<Content: View>(_ title: String, _ subtitle: String,
                                    @ViewBuilder control: () -> Content) -> some View {
        HStack(alignment: .center, spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Typo.body).fontWeight(.medium)
                if !subtitle.isEmpty {
                    Text(subtitle).font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            control()
        }
        .padding(.vertical, DS.Space.sm)
    }

    private func pill(_ text: String, _ color: Color, soft: Color) -> some View {
        HStack(spacing: DS.Space.xxs + 1) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(DS.Typo.caption).fontWeight(.medium)
        }
        .padding(.horizontal, DS.Space.xs).padding(.vertical, 3)
        .background(Capsule().fill(soft))
        .foregroundStyle(color)
    }

    private var askBackendSubtitle: String {
        if case .ok(let version) = askBackendStatus {
            return prefs.askBackend.displayName + " " + (version.split(separator: " ").first.map(String.init) ?? version)
        }
        return "Install and sign in to \(prefs.askBackend.displayName) to use Glance's AI features"
    }

    private func runTest() {
        backendTest.start(kind: prefs.askBackend)
    }

    private func testResultText(_ outcome: BackendTester.Outcome) -> String {
        switch outcome {
        case .success(let success):
            return String(format: "Responded in %.1fs — “%@”", success.latency, success.reply)
        case .failure(let message):
            return message
        }
    }

    private func rescanAskBackend() {
        switch prefs.askBackend {
        case .claude:
            if case .ok(_, let version) = ClaudeLocator.check() {
                askBackendStatus = .ok(version: version)
            } else {
                askBackendStatus = .notConnected
            }
        case .codex:
            if case .ok(_, let version) = CodexLocator.check() {
                askBackendStatus = .ok(version: version)
            } else {
                askBackendStatus = .notConnected
            }
        }
    }

    private var dailyTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.startOfDay(for: Date())
                    .addingTimeInterval(TimeInterval(prefs.schedDailyMinutes * 60))
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                prefs.schedDailyMinutes = (c.hour ?? 9) * 60 + (c.minute ?? 0)
            }
        )
    }

    private var briefingTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.startOfDay(for: Date())
                    .addingTimeInterval(TimeInterval(prefs.briefingMinutes * 60))
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                prefs.briefingMinutes = (c.hour ?? 9) * 60 + (c.minute ?? 0)
            }
        )
    }

    private func addRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a git repository the AI may work in"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let entry = RepoEntry(name: url.lastPathComponent, path: url.path)
        if !prefs.repos.contains(where: { $0.path == entry.path }) {
            prefs.repos.append(entry)
        }
    }
}
