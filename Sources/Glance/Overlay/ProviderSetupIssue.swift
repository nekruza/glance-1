import Foundation

/// Why the selected AI provider can't start, shown inside the overlay in
/// place of the prompt. (It used to be a modal alert with no overlay, which
/// made ⌥Space look broken.)
struct ProviderSetupIssue: Equatable {
    let title: String
    let detail: String
    /// Numbered fix-it steps; inline Markdown (`code`, **bold**).
    let steps: [String]
    /// One command worth copying into Terminal.
    let copyCommand: String?
    let helpURL: URL?

    static func make(kind: AskBackendKind, availability: AutomationAvailability) -> ProviderSetupIssue? {
        switch (kind, availability) {
        case (_, .available):
            return nil
        case (.claude, .notFound):
            return ProviderSetupIssue(
                title: "Claude Code isn't installed",
                detail: "Glance runs on your local Claude Code CLI, and couldn't find `claude` on this Mac. It doesn't need to be open — just installed and signed in.",
                steps: ["Install Claude Code — paste the command below into Terminal.",
                        "Run `claude` in Terminal once and sign in.",
                        "Come back and press **Try again**."],
                copyCommand: "curl -fsSL https://claude.ai/install.sh | bash",
                helpURL: URL(string: "https://code.claude.com/docs/en/setup"))
        case (.claude, .unusable(let path, let reason)):
            return ProviderSetupIssue(
                title: "Claude Code isn't working",
                detail: "Found it at \(path), but it couldn't be run (\(reason)).",
                steps: ["Run `claude --version` in Terminal to see the error.",
                        "Update or reinstall Claude Code if it fails.",
                        "Come back and press **Try again**."],
                copyCommand: "claude --version",
                helpURL: URL(string: "https://code.claude.com/docs/en/setup"))
        case (.codex, .notFound):
            return ProviderSetupIssue(
                title: "Codex CLI isn't installed",
                detail: "Glance is set to use your local Codex CLI, and couldn't find `codex` on this Mac.",
                steps: ["Install Codex CLI — paste the command below into Terminal.",
                        "Run `codex` in Terminal once and sign in with ChatGPT.",
                        "Come back and press **Try again** — or pick Claude Code in Settings."],
                copyCommand: "npm install -g @openai/codex",
                helpURL: URL(string: "https://github.com/openai/codex"))
        case (.codex, .unusable(let path, let reason)):
            return ProviderSetupIssue(
                title: "Codex CLI isn't working",
                detail: "Found it at \(path), but it couldn't be run (\(reason)).",
                steps: ["Run `codex --version` in Terminal to see the error.",
                        "Update or reinstall Codex CLI if it fails.",
                        "Come back and press **Try again**."],
                copyCommand: "codex --version",
                helpURL: URL(string: "https://github.com/openai/codex"))
        }
    }
}
