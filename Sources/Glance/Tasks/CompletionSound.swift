import AppKit

/// Completion chime: a macOS system sound, user-pickable in Settings.
/// Nil-safe — an unknown name just stays silent.
@MainActor
enum CompletionSound {

    /// System sounds that read as a "task done" chime.
    static let choices = ["Glass", "Pop", "Tink", "Purr", "Funk"]

    static func play() {
        guard Preferences.shared.completionSoundEnabled else { return }
        play(named: Preferences.shared.completionSoundName)
    }

    /// Direct play (settings preview).
    static func play(named name: String) {
        NSSound(named: name)?.play()
    }
}
