import SwiftUI

/// FR17 + FR18. FR19: nothing else in v1 — deliberately minimal.
struct SettingsView: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section {
                LabeledContent("Global hotkey") {
                    HotkeyRecorder(combo: $prefs.hotkey)
                        .frame(width: 140, height: 24)
                }
                Text("Press the shortcut anywhere to summon Glance. Requires at least one modifier.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLogin.set(newValue)
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 200)
        .navigationTitle("Glance Settings")
    }
}
