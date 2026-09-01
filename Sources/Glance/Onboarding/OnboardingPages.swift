import Foundation

/// One feature row on an onboarding page: SF symbol + short claim + one-line
/// detail. Pure data so tests can assert the tour actually covers the app.
struct OnboardingRow: Equatable {
    let symbol: String
    let title: String
    let detail: String
}

/// A single page of the first-launch tour.
struct OnboardingPage: Identifiable, Equatable {
    let id: String
    let symbol: String
    let title: String
    let subtitle: String
    let rows: [OnboardingRow]
}

/// The five-page tour content. Hotkey strings are injected so the copy always
/// shows the user's current bindings, not the shipped defaults.
enum OnboardingCatalog {

    static func pages(askHotkey: String, taskHotkey: String) -> [OnboardingPage] {
        [
            OnboardingPage(
                id: "welcome",
                symbol: "sparkle",
                title: "Welcome to Glance",
                subtitle: "A menu-bar AI assistant that answers questions about whatever is on your screen — without breaking your flow.",
                rows: [
                    OnboardingRow(
                        symbol: "menubar.rectangle",
                        title: "Lives in your menu bar",
                        detail: "Look for the sparkle icon at the top of your screen — no Dock icon, no window clutter."),
                    OnboardingRow(
                        symbol: "person.badge.key",
                        title: "No accounts, no API keys",
                        detail: "Glance runs on the Claude Code or Codex CLI already installed and signed in on this Mac."),
                    OnboardingRow(
                        symbol: "bolt",
                        title: "Instant from anywhere",
                        detail: "One global hotkey summons Glance over whatever app you're using."),
                ]),

            OnboardingPage(
                id: "ask",
                symbol: "bubble.left.and.bubble.right",
                title: "Ask about your screen",
                subtitle: "Press \(askHotkey) and a translucent overlay appears on top of your work.",
                rows: [
                    OnboardingRow(
                        symbol: "camera.viewfinder",
                        title: "Sees what you see",
                        detail: "Glance captures a still of the active display and can attach it to your question."),
                    OnboardingRow(
                        symbol: "text.alignleft",
                        title: "Answers stream inline",
                        detail: "Type a question and the answer streams back right in the overlay — ask follow-ups in the same breath."),
                    OnboardingRow(
                        symbol: "arrow.triangle.2.circlepath",
                        title: "Follow-ups stay fresh",
                        detail: "Each follow-up takes a new screenshot, with the overlay hidden so it's never in the shot."),
                    OnboardingRow(
                        symbol: "slider.horizontal.3",
                        title: "Make it yours",
                        detail: "Rebind the hotkey and tune the overlay opacity and accent color in Settings."),
                ]),

            OnboardingPage(
                id: "provider",
                symbol: "cpu",
                title: "Your AI, your account",
                subtitle: "Pick Claude Code or Codex in Settings — the selected local CLI powers every AI feature.",
                rows: [
                    OnboardingRow(
                        symbol: "checkmark.seal",
                        title: "One provider for everything",
                        detail: "Ask, task planning, drafts, connected-app pulls, and meeting summaries all use the CLI you choose."),
                    OnboardingRow(
                        symbol: "lock",
                        title: "Nothing stored by Glance",
                        detail: "Glance reuses the CLI's existing sign-in; usage counts against that account's own plan."),
                    OnboardingRow(
                        symbol: "arrow.left.arrow.right",
                        title: "Switch anytime",
                        detail: "Changing the provider in Settings cancels in-flight work and starts clean with the new one."),
                ]),

            OnboardingPage(
                id: "tasks",
                symbol: "checklist",
                title: "A task board that works with you",
                subtitle: "Press \(taskHotkey) for an AI task board that captures, triages, and drafts for you.",
                rows: [
                    OnboardingRow(
                        symbol: "tray.and.arrow.down",
                        title: "Pull your work in",
                        detail: "Connect Jira, Slack, Gmail, Granola, Calendar, and GitHub through Composio in Settings — with scheduled pulls and auto-triage."),
                    OnboardingRow(
                        symbol: "wand.and.stars",
                        title: "Agents & autopilot",
                        detail: "AI agents enrich new tasks and draft replies. Sending anything always waits for your explicit approval."),
                    OnboardingRow(
                        symbol: "checkmark.circle",
                        title: "Review queue",
                        detail: "Everything the AI proposes lands in a queue you approve item by item — nothing goes out on its own."),
                    OnboardingRow(
                        symbol: "sun.max",
                        title: "Morning briefing",
                        detail: "Each workday, a one-page briefing of your board is composed and waiting for you."),
                ]),

            OnboardingPage(
                id: "privacy",
                symbol: "lock.shield",
                title: "Meetings, privacy & permissions",
                subtitle: "Transcribe meetings on-device — and know exactly where your data goes.",
                rows: [
                    OnboardingRow(
                        symbol: "mic",
                        title: "Meeting transcription",
                        detail: "Start from the menu bar. Speech is transcribed on-device; notes and an AI summary are saved when you stop."),
                    OnboardingRow(
                        symbol: "text.badge.checkmark",
                        title: "Action items, extracted",
                        detail: "Your action items from each meeting land on the task board automatically."),
                    OnboardingRow(
                        symbol: "hand.raised",
                        title: "Permissions when needed",
                        detail: "Screen Recording is requested the first time you attach a screenshot; Microphone & Speech the first time you transcribe."),
                    OnboardingRow(
                        symbol: "network.slash",
                        title: "Private by design",
                        detail: "Glance makes no network calls of its own — traffic goes through your CLI. Screenshots may persist in that CLI's local session data; prune it anytime."),
                ]),
        ]
    }
}
