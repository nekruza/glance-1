import SwiftUI

/// FR17 + FR18, plus a Backend status/Test section (owner request). Still no
/// model picker / BYOK / MCP — those stay out of scope (FR14/FR19).
struct SettingsView: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    // Backend section state.
    @State private var status: ClaudeLocator.Status = ClaudeLocator.check()
    @State private var testing = false
    @State private var testResult: TestResult?

    private enum TestResult { case ok(String), fail(String) }

    var body: some View {
        Form {
            Section("Backend") {
                backendStatusRow
                if let result = testResult { resultRow(result) }
                HStack {
                    Button(testing ? "Testing…" : "Test") { runTest() }
                        .disabled(testing || !isOK)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Rescan") { rescan() }
                }
            }

            Section("Shortcut") {
                LabeledContent("Global hotkey") {
                    HotkeyRecorder(combo: $prefs.hotkey)
                        .frame(width: 140, height: 24)
                }
                Text("Press it anywhere to summon Glance. Requires at least one modifier.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in LaunchAtLogin.set(v) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 320)
        .navigationTitle("Glance Settings")
    }

    private var isOK: Bool { if case .ok = status { return true } else { return false } }

    @ViewBuilder private var backendStatusRow: some View {
        switch status {
        case .ok(let path, let version):
            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    Label("Claude Code \(version)", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text(path).font(.caption2).foregroundStyle(.secondary)
                }
            } label: { Text("Claude CLI") }
        case .notFound:
            Label("Claude CLI not found — install from claude.com/code",
                  systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .unusable(let path, let reason):
            Label("Found at \(path) but unusable (\(reason))",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder private func resultRow(_ r: TestResult) -> some View {
        switch r {
        case .ok(let msg):
            Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        case .fail(let msg):
            Label(msg, systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.callout)
        }
    }

    private func runTest() {
        testing = true
        testResult = nil
        BackendTester.test { result in
            testing = false
            switch result {
            case .success(let s):
                testResult = .ok(String(format: "Responded in %.1fs — \u{201C}%@\u{201D}", s.latency, s.reply))
            case .failure(let msg):
                testResult = .fail(msg)
            }
        }
    }

    private func rescan() {
        status = ClaudeLocator.check()
        testResult = nil
    }
}
