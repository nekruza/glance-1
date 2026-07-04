import SwiftUI

/// In-pane settings for the task overlay: left sidebar sections, right
/// content — dark, matching the overlay theme (the system Settings window
/// remains for the ask overlay's gear).
struct TaskSettingsView: View {

    enum Section: String, CaseIterable {
        case general = "General"
        case appearance = "Appearance"
        case ai = "AI & Runs"
        case repos = "Repos"
        case sources = "Sources"
        case connections = "Connections"
        case about = "About"

        var icon: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .appearance: return "sun.max"
            case .ai: return "cpu"
            case .repos: return "folder"
            case .sources: return "tray.and.arrow.down"
            case .connections: return "link"
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
        case .repos: reposSection
        case .sources: sourcesSection
        case .connections: connectionsSection
        case .about: aboutSection
        }
    }

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
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

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Composio MCP", "Read-only pulls: Jira / Granola / Slack / Calendar → Inbox") {
                VStack(alignment: .trailing, spacing: 4) {
                    TextField("MCP URL", text: $prefs.composioURL)
                        .textFieldStyle(.roundedBorder).frame(width: 200).font(.system(size: 10.5))
                    SecureField("API key (ck_…)", text: $prefs.composioKey)
                        .textFieldStyle(.roundedBorder).frame(width: 200).font(.system(size: 10.5))
                }
            }
            row("Scheduled pulls", "Fetch new work automatically") {
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
