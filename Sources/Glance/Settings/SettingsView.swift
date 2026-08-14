import SwiftUI

/// Settings built to 04-settings.html: General (hotkey, launch-at-login) and
/// Status (Screen Recording, selected local CLI backend) cards + privacy footnote.
/// No model picker / BYOK / MCP — out of scope (FR14/FR19).
struct SettingsView: View {
    static let aiProviderRowTitle = "AI provider"

    @ObservedObject private var prefs = Preferences.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    @State private var status: BackendStatus = .notConnected
    @State private var hasScreenPermission = ScreenCaptureService.hasPermission
    @State private var testing = false
    @State private var testResult: TestResult?

    private enum TestResult { case ok(String), fail(String) }
    private enum BackendStatus { case ok(String), notConnected }

    var body: some View {
        Form {
            Section("General") {
                LabeledContent {
                    HStack(spacing: 8) {
                        HotkeyRecorder(combo: $prefs.hotkey).frame(width: 150, height: 26)
                    }
                } label: {
                    settingLabel("Global hotkey", "Summons the overlay from any app")
                }
                LabeledContent {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { _, v in LaunchAtLogin.set(v) }
                } label: {
                    settingLabel("Launch at login", "Start in the menu bar when you sign in")
                }
                LabeledContent {
                    Picker("", selection: $prefs.askBackend) {
                        ForEach(AskBackendKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                } label: {
                    settingLabel(Self.aiProviderRowTitle, "Local CLI used for Ask, tasks, suggestions, meetings, and Composio")
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        Slider(value: $prefs.overlayOpacity, in: 0.2...1.0)
                            .frame(width: 140)
                        Text("\(Int(prefs.overlayOpacity * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                        Button("Reset") {
                            prefs.overlayOpacity = Preferences.defaultOverlayOpacity
                        }
                        .controlSize(.small)
                        .disabled(prefs.overlayOpacity == Preferences.defaultOverlayOpacity)
                    }
                } label: {
                    settingLabel("Overlay opacity", "How solid the overlay background is")
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        ColorPicker("", selection: $prefs.accentColor, supportsOpacity: false)
                            .labelsHidden()
                        Button("Reset") {
                            prefs.accentHex = Preferences.defaultAccentHex
                        }
                        .controlSize(.small)
                        .disabled(prefs.accentHex == Preferences.defaultAccentHex)
                    }
                } label: {
                    settingLabel("Accent color", "Icons, highlights and cursor in the overlay")
                }
            }

            Section("Tasks") {
                LabeledContent {
                    HotkeyRecorder(combo: $prefs.taskHotkey).frame(width: 150, height: 26)
                } label: {
                    settingLabel("Task board hotkey", "Summons the AI task board")
                }
                LabeledContent {
                    Toggle("", isOn: $prefs.autoPlanApprove)
                        .labelsHidden()
                        .toggleStyle(.switch)
                } label: {
                    settingLabel("Auto-approve small plans",
                                 "Skip the plan gate for non-code tasks ≤1h with no external actions. Code tasks are always gated.")
                }
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 4) {
                        TextField("MCP URL", text: $prefs.composioURL)
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                            .font(.system(size: 11))
                        SecureField("API key (ck_…)", text: $prefs.composioKey)
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                            .font(.system(size: 11))
                    }
                } label: {
                    settingLabel("Composio (read-only pulls)",
                                 "Jira / Slack / Granola → Inbox. Fetch only — Glance never writes to them.")
                }
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 6) {
                        Toggle("", isOn: $prefs.schedEnabled)
                            .labelsHidden().toggleStyle(.switch)
                        if prefs.schedEnabled {
                            HStack(spacing: 6) {
                                Picker("", selection: $prefs.schedSource) {
                                    Text("All sources").tag("All")
                                    ForEach(ComposioIngest.Source.allCases, id: \.rawValue) { s in
                                        Text(s.rawValue).tag(s.rawValue)
                                    }
                                }
                                .labelsHidden().frame(width: 110)
                                Picker("", selection: $prefs.schedMode) {
                                    ForEach(Preferences.ScheduleMode.allCases, id: \.self) { m in
                                        Text(m.rawValue).tag(m)
                                    }
                                }
                                .labelsHidden().frame(width: 130)
                            }
                            if prefs.schedMode == .daily {
                                DatePicker("", selection: dailyTimeBinding,
                                           displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                            }
                        }
                    }
                } label: {
                    settingLabel("Scheduled pulls",
                                 "Automatically fetch new work into the Inbox on a cadence")
                }
                VStack(alignment: .leading, spacing: 6) {
                    settingLabel("Repos", "Where AI agents run code tasks (isolated worktrees)")
                    ForEach(prefs.repos) { repo in
                        HStack {
                            Text(repo.name).font(.system(size: 12, weight: .medium))
                            Text(repo.path).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(role: .destructive) {
                                prefs.repos.removeAll { $0.id == repo.id }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                        }
                    }
                    Button("Add repo…") { addRepo() }
                        .controlSize(.small)
                }
            }

            Section("Status") {
                LabeledContent {
                    if hasScreenPermission {
                        pill("Granted", DS.success)
                    } else {
                        HStack(spacing: 8) {
                            Button("Grant") { PermissionOnboarding.promptForScreenRecording() }
                            pill("Not granted", DS.warning)
                        }
                    }
                } label: {
                    settingLabel("Screen Recording", "Required to capture the active display")
                }

                LabeledContent {
                    HStack(spacing: 10) {
                        if case .ok(let v) = status {
                            Text(shortVersion(v)).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            pill("Connected", DS.success)
                        } else {
                            pill("Not connected", DS.warning)
                        }
                    }
                } label: {
                    settingLabel("AI provider: \(prefs.askBackend.displayName)", backendSubtitle)
                }

                if let r = testResult { resultRow(r) }

                HStack {
                    Button(testing ? "Testing…" : "Test") { runTest() }
                        .disabled(testing || !isOK)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Rescan") { rescan() }
                }
            }

            Section {
                Text(privacyNote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 400)
        .navigationTitle("Glance Settings")
        .onAppear {
            rescan()
        }
        .onChange(of: prefs.askBackend) { _, _ in
            rescan()
        }
    }

    private var isOK: Bool { if case .ok = status { return true } else { return false } }

    private func settingLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(color)
    }

    @ViewBuilder private func resultRow(_ r: TestResult) -> some View {
        switch r {
        case .ok(let m):
            Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(DS.success).font(.callout)
        case .fail(let m):
            Label(m, systemImage: "exclamationmark.circle.fill").foregroundStyle(DS.warning).font(.callout)
        }
    }

    private var backendSubtitle: String {
        switch prefs.askBackend {
        case .claude: return "Local \(prefs.askBackend.displayName) — reuses its own auth"
        case .codex: return "Local \(prefs.askBackend.displayName) — reuses its own auth"
        }
    }

    private var privacyNote: String {
        switch prefs.askBackend {
        case .claude:
            return "No API keys stored. AI-provider traffic goes through your local \(prefs.askBackend.displayName). Screenshots may persist in Claude Code session transcripts under ~/.claude/projects/ — see README."
        case .codex:
            return "No API keys stored by Glance. Attached screenshots use a private temporary PNG during the \(prefs.askBackend.displayName) turn and are deleted on completion or cancellation. Codex may retain its own session data — see README."
        }
    }

    private func shortVersion(_ raw: String) -> String {
        let first = raw.split(separator: " ").first.map(String.init) ?? raw
        switch prefs.askBackend {
        case .claude:
            return "claude " + first
        case .codex:
            return raw.lowercased().hasPrefix("codex") ? raw : "codex " + first
        }
    }

    private func runTest() {
        testing = true; testResult = nil
        let kind = prefs.askBackend
        BackendTester.test(kind: kind) { outcome in
            guard prefs.askBackend == kind else { return }
            testing = false
            switch outcome {
            case .success(let s):
                testResult = .ok(String(format: "Responded in %.1fs — \u{201C}%@\u{201D}", s.latency, s.reply))
            case .failure(let msg):
                testResult = .fail(msg)
            }
        }
    }

    /// Bridges "minutes since midnight" to a DatePicker time.
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

    private func rescan() {
        switch prefs.askBackend {
        case .claude:
            if case .ok(_, let version) = ClaudeLocator.check() {
                status = .ok(version)
            } else {
                status = .notConnected
            }
        case .codex:
            if case .ok(_, let version) = CodexLocator.check() {
                status = .ok(version)
            } else {
                status = .notConnected
            }
        }
        hasScreenPermission = ScreenCaptureService.hasPermission
        testing = false
        testResult = nil
    }
}
