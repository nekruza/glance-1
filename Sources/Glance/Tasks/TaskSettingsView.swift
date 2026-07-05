import SwiftUI

/// In-window settings for the Tasks app window: left sidebar sections, right
/// content — light DS design (the system Settings window remains as a
/// fallback when the task system is unavailable).
struct TaskSettingsView: View {

    enum Section: String, CaseIterable {
        case general = "General"
        case appearance = "Appearance"
        case ai = "AI & Runs"
        case agents = "Agents"
        case repos = "Repos"
        case connections = "Connections"
        case schedule = "Schedule"
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
            case .about: return "info.circle"
            }
        }
    }

    @ObservedObject private var prefs = Preferences.shared
    @State private var section: Section = .general
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var cliStatus: ClaudeLocator.Status = ClaudeLocator.check()
    @State private var testing = false
    @State private var testResult: String?

    @State private var connections: [ComposioIngest.Connection] = []
    @State private var connectionsLoading = false
    @State private var connectionsError: String?
    @State private var connectionsCheckedAt: Date?

    @ObservedObject var session: TaskBoardSession
    var onClose: () -> Void

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
                        .frame(maxWidth: 560, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(DS.bg)
            }
            .frame(maxHeight: .infinity)
        }
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
        case .about: aboutSection
        }
    }

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            row("Composio MCP", "Read-only pulls: Jira / Granola / Slack / Calendar → Inbox") {
                VStack(alignment: .trailing, spacing: DS.Space.xxs) {
                    TextField("MCP URL", text: $prefs.composioURL)
                        .textFieldStyle(.roundedBorder).frame(width: 200).font(DS.Typo.caption)
                    SecureField("API key (ck_…)", text: $prefs.composioKey)
                        .textFieldStyle(.roundedBorder).frame(width: 200).font(DS.Typo.caption)
                }
            }
            Divider().overlay(DS.divider)
            HStack {
                Text("Apps linked to your Composio account. Pulls only work for active connections.")
                    .font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
                Spacer()
                Button(action: refreshConnections) {
                    HStack(spacing: DS.Space.xxs) {
                        if connectionsLoading { ProgressView().controlSize(.mini) }
                        Text(connectionsLoading ? "Checking…" : "Refresh")
                    }
                }
                .controlSize(.small)
                .disabled(connectionsLoading)
            }

            if let err = connectionsError {
                Text(err).font(DS.Typo.caption).foregroundStyle(DS.danger)
            }

            if connections.isEmpty && !connectionsLoading && connectionsError == nil {
                Text(connectionsCheckedAt == nil
                     ? "Click Refresh to check your connections."
                     : "No connections found.")
                    .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
            }

            ForEach(connections) { c in
                Hover { hovering in
                    HStack(spacing: DS.Space.xs + 2) {
                        Image(systemName: iconForApp(c.app))
                            .font(DS.Typo.label)
                            .foregroundStyle(DS.textSecondary)
                            .frame(width: 16)
                        Text(c.app.capitalized).font(DS.Typo.label)
                        Spacer()
                        pill(c.isActive ? "Active" : c.status.capitalized,
                             c.isActive ? DS.success : DS.warning,
                             soft: c.isActive ? DS.successSoft : DS.warningSoft)
                    }
                    .padding(.vertical, DS.Space.xxs + 1).padding(.horizontal, DS.Space.xs + 2)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.small)
                        .fill(hovering ? DS.surfaceHover : DS.bg))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.small)
                        .strokeBorder(DS.border, lineWidth: 1))
                }
            }

            if let at = connectionsCheckedAt {
                Text("Checked \(at.formatted(date: .omitted, time: .shortened))")
                    .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
            }

            Divider().overlay(DS.divider)
            HStack {
                Text("Add or repair connections in the Composio dashboard.")
                    .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
                Spacer()
                Button("Open dashboard") {
                    NSWorkspace.shared.open(URL(string: "https://dashboard.composio.dev/")!)
                }
                .controlSize(.small)
            }
        }
    }

    private func refreshConnections() {
        connectionsLoading = true
        connectionsError = nil
        session.listConnections { list, error in
            connectionsLoading = false
            connectionsCheckedAt = Date()
            if let list {
                connections = list.sorted { $0.app < $1.app }
            } else {
                connectionsError = error
            }
        }
    }

    private func iconForApp(_ app: String) -> String {
        switch app.lowercased() {
        case let a where a.contains("jira"): return "ticket"
        case let a where a.contains("slack"): return "number"
        case let a where a.contains("granola"): return "mic"
        case let a where a.contains("calendar"): return "calendar"
        case let a where a.contains("gmail"): return "envelope"
        case let a where a.contains("github"): return "chevron.left.forwardslash.chevron.right"
        default: return "app.connected.to.app.below.fill"
        }
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
            row("Confetti", "Celebrate completions on the canvas (off automatically with Reduce Motion)") {
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
            row("Claude CLI", cliSubtitle) {
                HStack(spacing: DS.Space.xs) {
                    if case .ok = cliStatus {
                        pill("Connected", DS.success, soft: DS.successSoft)
                    } else {
                        pill("Not connected", DS.warning, soft: DS.warningSoft)
                    }
                    Button(testing ? "Testing…" : "Test") { runTest() }
                        .controlSize(.small)
                        .disabled(testing)
                }
            }
            if let r = testResult {
                Text(r).font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
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

    // MARK: - Agents

    @State private var editingAgentId: UUID?
    @State private var generateRequest = ""
    @State private var generating = false
    @State private var generateError: String?

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("Skill profiles. New tasks are routed to the best fit by AI; you can override per task. A profile sets the persona, preferred model, and which tools its runs may use.")
                .font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(prefs.agents) { agent in
                agentRow(agent)
            }

            // AI-generated agent: describe the need, Opus designs the profile.
            VStack(alignment: .leading, spacing: DS.Space.xxs + 2) {
                overline("Create with AI")
                HStack(spacing: DS.Space.xs) {
                    TextField("Describe the agent you need — e.g. “SQL analyst for our metrics DB, careful with joins”",
                              text: $generateRequest)
                        .textFieldStyle(.roundedBorder).font(DS.Typo.caption)
                        .onSubmit { generateAgent() }
                    Button(action: { generateAgent() }) {
                        HStack(spacing: DS.Space.xxs) {
                            if generating { ProgressView().controlSize(.mini) }
                            Text(generating ? "Designing…" : "Generate")
                        }
                    }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .disabled(generating || generateRequest.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let err = generateError {
                    Text(err).font(DS.Typo.caption).foregroundStyle(DS.danger)
                }
                Text("Opus writes the persona, picks the model and least-privilege tools. Review and tweak before first use.")
                    .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
            }
            .padding(DS.Space.sm)
            .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.surface))

            Button("Add agent manually…") {
                let fresh = AgentProfile(name: "New agent", icon: "🤖",
                                         skills: "Describe what this agent is best at",
                                         systemPrompt: "", preferredModel: nil,
                                         allowedTools: ["Read", "Glob", "Grep"])
                prefs.agents.append(fresh)
                editingAgentId = fresh.id
            }
            .controlSize(.small)
        }
    }

    private func generateAgent() {
        let request = generateRequest.trimmingCharacters(in: .whitespaces)
        guard !request.isEmpty, !generating else { return }
        generating = true
        generateError = nil
        session.generateAgent(request: request) { profile in
            generating = false
            guard let profile else {
                generateError = "Couldn't design an agent — try rephrasing."
                return
            }
            prefs.agents.append(profile)
            editingAgentId = profile.id
            generateRequest = ""
        }
    }

    @ViewBuilder private func agentRow(_ agent: AgentProfile) -> some View {
        let editing = editingAgentId == agent.id
        Hover { hovering in
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.xs) {
                    Text(agent.icon).font(DS.Typo.headline).frame(width: 18)
                    Text(agent.name).font(DS.Typo.label)
                    if agent.isBuiltIn {
                        dsBadge("built-in", tint: DS.textTertiary, soft: DS.surface)
                    }
                    Spacer()
                    Text(agent.preferredModel ?? "auto")
                        .font(DS.Typo.mono).foregroundStyle(DS.textTertiary)
                    Button(editing ? "Done" : "Edit") {
                        editingAgentId = editing ? nil : agent.id
                    }
                    .buttonStyle(.plain).font(DS.Typo.label).foregroundStyle(DS.accentText)
                }
                if !editing {
                    Text(agent.skills).font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                } else {
                    agentEditor(agent)
                }
            }
            .padding(.vertical, DS.Space.xs).padding(.horizontal, DS.Space.sm)
            .background(RoundedRectangle(cornerRadius: DS.Radius.medium)
                .fill(hovering && !editing ? DS.surfaceHover : DS.bg))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium)
                .strokeBorder(DS.border, lineWidth: 1))
        }
    }

    private func agentEditor(_ agent: AgentProfile) -> some View {
        func bind<T>(_ keyPath: WritableKeyPath<AgentProfile, T>) -> Binding<T> {
            Binding(
                get: {
                    prefs.agents.first { $0.id == agent.id }?[keyPath: keyPath]
                        ?? agent[keyPath: keyPath]
                },
                set: { newValue in
                    guard let idx = prefs.agents.firstIndex(where: { $0.id == agent.id }) else { return }
                    prefs.agents[idx][keyPath: keyPath] = newValue
                }
            )
        }
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                TextField("Name", text: bind(\.name))
                    .textFieldStyle(.roundedBorder).font(DS.Typo.caption).frame(width: 130)
                TextField("Emoji", text: bind(\.icon))
                    .textFieldStyle(.roundedBorder).font(DS.Typo.caption).frame(width: 60)
                Picker("", selection: bind(\.preferredModel)) {
                    Text("auto").tag(String?.none)
                    ForEach(["haiku", "sonnet", "opus"], id: \.self) { m in
                        Text(m).tag(String?.some(m))
                    }
                }
                .labelsHidden().controlSize(.small).frame(width: 90)
            }
            TextField("Skills (used for AI routing)", text: bind(\.skills))
                .textFieldStyle(.roundedBorder).font(DS.Typo.caption)
            overline("System prompt")
            TextEditor(text: bind(\.systemPrompt))
                .font(DS.Typo.mono)
                .scrollContentBackground(.hidden)
                .frame(height: 90)
                .padding(DS.Space.xxs + 2)
                .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.codeBg))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.small)
                    .strokeBorder(DS.border, lineWidth: 1))
            overline("Tools")
            HStack(spacing: DS.Space.xs + 2) {
                ForEach(AgentProfile.toolVocabulary, id: \.self) { tool in
                    Toggle(tool, isOn: Binding(
                        get: { (prefs.agents.first { $0.id == agent.id }?.allowedTools ?? []).contains(tool) },
                        set: { on in
                            guard let idx = prefs.agents.firstIndex(where: { $0.id == agent.id }) else { return }
                            if on {
                                if !prefs.agents[idx].allowedTools.contains(tool) {
                                    prefs.agents[idx].allowedTools.append(tool)
                                }
                            } else {
                                prefs.agents[idx].allowedTools.removeAll { $0 == tool }
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(DS.Typo.caption)
                }
            }
            HStack {
                if agent.isBuiltIn {
                    Button("Reset to shipped definition") {
                        if let shipped = AgentProfile.builtIns.first(where: { $0.name == agent.name }),
                           let idx = prefs.agents.firstIndex(where: { $0.id == agent.id }) {
                            var restored = shipped
                            restored.id = agent.id // keep task references intact
                            restored.isBuiltIn = true
                            prefs.agents[idx] = restored
                        }
                    }
                    .controlSize(.small)
                } else {
                    Button("Delete agent", role: .destructive) {
                        prefs.agents.removeAll { $0.id == agent.id }
                        editingAgentId = nil
                    }
                    .controlSize(.small)
                }
                Spacer()
            }
            Text("Boundary actions (git push, PR/API writes) stay blocked for every agent.")
                .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
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
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("Glance v1.0").font(DS.Typo.title)
            Text("Personal AI assistant: ask-anything overlay, meeting transcription, and an AI task board — all running through your local Claude CLI.")
                .font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
            Divider().overlay(DS.divider)
            Text("No API keys for model traffic — everything goes through your local Claude CLI and its auth. Task data stays in ~/Library/Application Support/Glance. The Composio key (Sources) is the one stored credential, used for read-only pulls.")
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

    private var cliSubtitle: String {
        if case .ok(_, let v) = cliStatus {
            return "claude " + (v.split(separator: " ").first.map(String.init) ?? v)
        }
        return "Install/authenticate the Claude CLI to run tasks"
    }

    private func runTest() {
        testing = true
        testResult = nil
        BackendTester.test { outcome in
            testing = false
            switch outcome {
            case .success(let s):
                testResult = String(format: "Responded in %.1fs — “%@”", s.latency, s.reply)
            case .failure(let msg):
                testResult = msg
            }
            cliStatus = ClaudeLocator.check()
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
