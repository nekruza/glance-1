import SwiftUI

/// Settings built to 04-settings.html: General (hotkey, launch-at-login) and
/// Status (Screen Recording, Claude CLI backend) cards + privacy footnote.
/// No model picker / BYOK / MCP — out of scope (FR14/FR19).
struct SettingsView: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    @State private var status: ClaudeLocator.Status = ClaudeLocator.check()
    @State private var hasScreenPermission = ScreenCaptureService.hasPermission
    @State private var testing = false
    @State private var testResult: TestResult?

    private enum TestResult { case ok(String), fail(String) }

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
                        pill("Granted", .green)
                    } else {
                        HStack(spacing: 8) {
                            Button("Grant") { PermissionOnboarding.promptForScreenRecording() }
                            pill("Not granted", .orange)
                        }
                    }
                } label: {
                    settingLabel("Screen Recording", "Required to capture the active display")
                }

                LabeledContent {
                    HStack(spacing: 10) {
                        if case .ok(_, let v) = status {
                            Text(shortVersion(v)).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            pill("Connected", .green)
                        } else {
                            pill("Not connected", .orange)
                        }
                    }
                } label: {
                    settingLabel("Claude CLI backend", "Local Claude Code — reuses its own auth")
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
                Text("No API keys stored. All model traffic goes through your local Claude CLI. Screenshots may persist in Claude Code session transcripts under ~/.claude/projects/ — see README.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 400)
        .navigationTitle("Glance Settings")
        .onAppear {
            status = ClaudeLocator.check()
            hasScreenPermission = ScreenCaptureService.hasPermission
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
            Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        case .fail(let m):
            Label(m, systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.callout)
        }
    }

    private func shortVersion(_ raw: String) -> String {
        "claude " + (raw.split(separator: " ").first.map(String.init) ?? raw)
    }

    private func runTest() {
        testing = true; testResult = nil
        BackendTester.test { outcome in
            testing = false
            switch outcome {
            case .success(let s):
                testResult = .ok(String(format: "Responded in %.1fs — \u{201C}%@\u{201D}", s.latency, s.reply))
            case .failure(let msg):
                testResult = .fail(msg)
            }
        }
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
        status = ClaudeLocator.check()
        hasScreenPermission = ScreenCaptureService.hasPermission
        testResult = nil
    }
}
