import SwiftUI

/// In-pane settings for the task overlay: left sidebar sections, right
/// content — dark, matching the overlay theme (the system Settings window
/// remains for the ask overlay's gear).
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
            Divider().overlay(Theme.glassBorder)
            HStack(spacing: 0) {
                sidebar
                Divider().overlay(Theme.glassBorder)
                ScrollView {
                    content
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Label("Back", systemImage: "chevron.left")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            Text("SETTINGS")
                .font(.system(size: 9, weight: .bold)).tracking(1)
                .foregroundStyle(Theme.faint)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.allCases, id: \.self) { s in
                let selected = section == s
                Button(action: { section = s }) {
                    HStack(spacing: 8) {
                        Image(systemName: s.icon)
                            .font(.system(size: 11))
                            .frame(width: 16)
                        Text(s.rawValue).font(.system(size: 12, weight: selected ? .semibold : .regular))
                        Spacer()
                    }
                    .foregroundStyle(selected ? Theme.fg : Theme.muted)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(selected ? Color.white.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 170)
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
        VStack(alignment: .leading, spacing: 12) {
            row("Composio MCP", "Read-only pulls: Jira / Granola / Slack / Calendar → Inbox") {
                VStack(alignment: .trailing, spacing: 4) {
                    TextField("MCP URL", text: $prefs.composioURL)
                        .textFieldStyle(.roundedBorder).frame(width: 200).font(.system(size: 10.5))
                    SecureField("API key (ck_…)", text: $prefs.composioKey)
                        .textFieldStyle(.roundedBorder).frame(width: 200).font(.system(size: 10.5))
                }
            }
            Divider().overlay(Theme.glassBorder)
            HStack {
                Text("Apps linked to your Composio account. Pulls only work for active connections.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                Button(action: refreshConnections) {
                    HStack(spacing: 5) {
                        if connectionsLoading { ProgressView().controlSize(.mini) }
                        Text(connectionsLoading ? "Checking…" : "Refresh")
                    }
                }
                .controlSize(.small)
                .disabled(connectionsLoading)
            }

            if let err = connectionsError {
                Text(err).font(.system(size: 11)).foregroundStyle(Theme.danger)
            }

            if connections.isEmpty && !connectionsLoading && connectionsError == nil {
                Text(connectionsCheckedAt == nil
                     ? "Click Refresh to check your connections."
                     : "No connections found.")
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
            }

            ForEach(connections) { c in
                HStack(spacing: 10) {
                    Image(systemName: iconForApp(c.app))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 16)
                    Text(c.app.capitalized).font(.system(size: 12, weight: .medium))
                    Spacer()
                    pill(c.isActive ? "Active" : c.status.capitalized,
                         c.isActive ? Theme.success : .orange)
                }
                .padding(.vertical, 5).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
            }

            if let at = connectionsCheckedAt {
                Text("Checked \(at.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 9.5)).foregroundStyle(Theme.faint)
            }

            Divider().overlay(Theme.glassBorder)
            HStack {
                Text("Add or repair connections in the Composio dashboard.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.faint)
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
        VStack(alignment: .leading, spacing: 14) {
            row("Ask overlay hotkey", "Summon the ask-anything overlay") {
                HotkeyRecorder(combo: $prefs.hotkey).frame(width: 140, height: 24)
            }
            row("Task board hotkey", "Summon this board") {
                HotkeyRecorder(combo: $prefs.taskHotkey).frame(width: 140, height: 24)
            }
            row("Launch at login", "Start in the menu bar when you sign in") {
                Toggle("", isOn: $launchAtLogin)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .onChange(of: launchAtLogin) { _, v in LaunchAtLogin.set(v) }
            }
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Overlay opacity", "How solid the overlay background is") {
                HStack(spacing: 8) {
                    Slider(value: $prefs.overlayOpacity, in: 0.2...1.0).frame(width: 130)
                    Text("\(Int(prefs.overlayOpacity * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.muted).frame(width: 32, alignment: .trailing)
                }
            }
            row("Accent color", "Icons, highlights and cursor") {
                HStack(spacing: 8) {
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
        VStack(alignment: .leading, spacing: 14) {
            row("Claude CLI", cliSubtitle) {
                HStack(spacing: 8) {
                    if case .ok = cliStatus {
                        pill("Connected", Theme.success)
                    } else {
                        pill("Not connected", .orange)
                    }
                    Button(testing ? "Testing…" : "Test") { runTest() }
                        .controlSize(.small)
                        .disabled(testing)
                }
            }
            if let r = testResult {
                Text(r).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Skill profiles. New tasks are routed to the best fit by AI; you can override per task. A profile sets the persona, preferred model, and which tools its runs may use.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(prefs.agents) { agent in
                agentRow(agent)
            }

            // AI-generated agent: describe the need, Opus designs the profile.
            VStack(alignment: .leading, spacing: 6) {
                Text("CREATE WITH AI").font(.system(size: 8.5, weight: .bold)).tracking(0.5)
                    .foregroundStyle(Theme.faint)
                HStack(spacing: 8) {
                    TextField("Describe the agent you need — e.g. “SQL analyst for our metrics DB, careful with joins”",
                              text: $generateRequest)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                        .onSubmit { generateAgent() }
                    Button(action: { generateAgent() }) {
                        HStack(spacing: 5) {
                            if generating { ProgressView().controlSize(.mini) }
                            Text(generating ? "Designing…" : "Generate")
                        }
                    }
                    .controlSize(.small)
                    .disabled(generating || generateRequest.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let err = generateError {
                    Text(err).font(.system(size: 10.5)).foregroundStyle(Theme.danger)
                }
                Text("Opus writes the persona, picks the model and least-privilege tools. Review and tweak before first use.")
                    .font(.system(size: 9.5)).foregroundStyle(Theme.faint)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))

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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(agent.icon).font(.system(size: 13)).frame(width: 18)
                Text(agent.name).font(.system(size: 12, weight: .medium))
                if agent.isBuiltIn {
                    Text("built-in").font(.system(size: 8.5, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.field))
                        .foregroundStyle(Theme.faint)
                }
                Spacer()
                Text(agent.preferredModel ?? "auto")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.faint)
                Button(editing ? "Done" : "Edit") {
                    editingAgentId = editing ? nil : agent.id
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
            }
            if !editing {
                Text(agent.skills).font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                    .lineLimit(1)
            } else {
                agentEditor(agent)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
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
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Name", text: bind(\.name))
                    .textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(width: 130)
                TextField("Emoji", text: bind(\.icon))
                    .textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(width: 60)
                Picker("", selection: bind(\.preferredModel)) {
                    Text("auto").tag(String?.none)
                    ForEach(["haiku", "sonnet", "opus"], id: \.self) { m in
                        Text(m).tag(String?.some(m))
                    }
                }
                .labelsHidden().controlSize(.small).frame(width: 90)
            }
            TextField("Skills (used for AI routing)", text: bind(\.skills))
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
            Text("SYSTEM PROMPT").font(.system(size: 8.5, weight: .bold)).tracking(0.5)
                .foregroundStyle(Theme.faint)
            TextEditor(text: bind(\.systemPrompt))
                .font(.system(size: 11))
                .scrollContentBackground(.hidden)
                .frame(height: 90)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.codeBg))
            Text("TOOLS").font(.system(size: 8.5, weight: .bold)).tracking(0.5)
                .foregroundStyle(Theme.faint)
            HStack(spacing: 10) {
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
                    .font(.system(size: 10))
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
                .font(.system(size: 9.5)).foregroundStyle(Theme.faint)
        }
    }

    private var reposSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where AI agents run code tasks — always in an isolated worktree, never your live checkout.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            ForEach(prefs.repos) { repo in
                HStack {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.faint)
                    Text(repo.name).font(.system(size: 12, weight: .medium))
                    Text(repo.path).font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(action: { prefs.repos.removeAll { $0.id == repo.id } }) {
                        Image(systemName: "minus.circle").font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
            }
            Button("Add repo…") { addRepo() }.controlSize(.small)
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Scheduled pulls", "Fetch new work automatically into the Inbox") {
                Toggle("", isOn: $prefs.schedEnabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if prefs.schedEnabled {
                row("Schedule", "") {
                    HStack(spacing: 6) {
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Glance v1.0").font(.system(size: 13, weight: .semibold))
            Text("Personal AI assistant: ask-anything overlay, meeting transcription, and an AI task board — all running through your local Claude CLI.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            Divider().overlay(Theme.glassBorder)
            Text("No API keys for model traffic — everything goes through your local Claude CLI and its auth. Task data stays in ~/Library/Application Support/Glance. The Composio key (Sources) is the one stored credential, used for read-only pulls.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.faint)
        }
    }

    // MARK: - Bits

    private func row<Content: View>(_ title: String, _ subtitle: String,
                                    @ViewBuilder control: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            control()
        }
        .padding(.vertical, 2)
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10.5, weight: .medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
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
