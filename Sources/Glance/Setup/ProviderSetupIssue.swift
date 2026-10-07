import Foundation

/// Why the selected AI provider can't answer, shown inside the overlay in
/// place of the prompt. (It used to be a modal alert with no overlay, which
/// made ⌥Space look broken.)
struct ProviderSetupIssue: Equatable {
    enum Problem: Equatable {
        case notInstalled, broken, signedOut
    }

    /// The one-click fix: run `command` in Terminal (see `TerminalLauncher`).
    struct TerminalAction: Equatable {
        let label: String
        let command: String
    }

    let problem: Problem
    let title: String
    let detail: String
    /// Numbered fix-it steps; inline Markdown (`code`, **bold**).
    let steps: [String]
    /// The command as a person would type it, for the copy row.
    let copyCommand: String?
    let terminalAction: TerminalAction?
    let helpURL: URL?

    private static let claudeInstall = "curl -fsSL https://claude.ai/install.sh | bash"
    private static let codexInstall = "npm install -g @openai/codex"
    private static let claudeGuide = URL(string: "https://code.claude.com/docs/en/setup")
    private static let codexGuide = URL(string: "https://github.com/openai/codex")

    static func make(kind: AskBackendKind, availability: AutomationAvailability) -> ProviderSetupIssue? {
        let q = TerminalLauncher.quote
        switch (kind, availability) {
        case (_, .available):
            return nil
        case (.claude, .notFound):
            return ProviderSetupIssue(
                problem: .notInstalled,
                title: "Claude Code isn't installed",
                detail: "Glance runs on your local Claude Code CLI, and couldn't find `claude` on this Mac. It doesn't need to be open — just installed and signed in.",
                steps: ["Press **Install in Terminal** (or paste the command below into Terminal).",
                        "If Glance then asks you to sign in, press **Sign in**.",
                        "Glance notices when it's done — or press **Try again**."],
                copyCommand: claudeInstall,
                terminalAction: TerminalAction(label: "Install in Terminal", command: claudeInstall),
                helpURL: claudeGuide)
        case (.claude, .unusable(let path, let reason)):
            return ProviderSetupIssue(
                problem: .broken,
                title: "Claude Code isn't working",
                detail: "Found it at \(path), but it couldn't be run (\(reason)).",
                steps: ["Press **Run in Terminal** to see the error from `claude --version`.",
                        "Update or reinstall Claude Code if it fails.",
                        "Glance notices when it's fixed — or press **Try again**."],
                copyCommand: "claude --version",
                terminalAction: TerminalAction(label: "Run in Terminal", command: "\(q(path)) --version"),
                helpURL: claudeGuide)
        case (.codex, .notFound):
            return ProviderSetupIssue(
                problem: .notInstalled,
                title: "Codex CLI isn't installed",
                detail: "Glance is set to use your local Codex CLI, and couldn't find `codex` on this Mac.",
                steps: ["Press **Install in Terminal** (needs Node.js), or paste the command below.",
                        "If Glance then asks you to sign in, press **Sign in** (`codex` uses ChatGPT).",
                        "Glance notices when it's done — or press **Try again**, or pick Claude Code in Settings."],
                copyCommand: codexInstall,
                terminalAction: TerminalAction(label: "Install in Terminal", command: codexInstall),
                helpURL: codexGuide)
        case (.codex, .unusable(let path, let reason)):
            return ProviderSetupIssue(
                problem: .broken,
                title: "Codex CLI isn't working",
                detail: "Found it at \(path), but it couldn't be run (\(reason)).",
                steps: ["Press **Run in Terminal** to see the error from `codex --version`.",
                        "Update or reinstall Codex CLI if it fails.",
                        "Glance notices when it's fixed — or press **Try again**."],
                copyCommand: "codex --version",
                terminalAction: TerminalAction(label: "Run in Terminal", command: "\(q(path)) --version"),
                helpURL: codexGuide)
        }
    }

    /// The CLI answered "not signed in". Sign-in runs the exact binary Glance
    /// found, which may not be on Terminal's PATH.
    static func signedOut(kind: AskBackendKind, binaryPath: String) -> ProviderSetupIssue {
        let q = TerminalLauncher.quote(binaryPath)
        switch kind {
        case .claude:
            return ProviderSetupIssue(
                problem: .signedOut,
                title: "Sign in to Claude Code",
                detail: "Claude Code is installed but not signed in, so it couldn't answer. Your question is still in the box — send it again once you're in.",
                steps: ["Press **Sign in** — Terminal opens and runs `claude auth login`.",
                        "Finish signing in in your browser.",
                        "Glance notices on its own — or press **Try again**."],
                copyCommand: "claude auth login",
                terminalAction: TerminalAction(label: "Sign in", command: "\(q) auth login"),
                helpURL: claudeGuide)
        case .codex:
            return ProviderSetupIssue(
                problem: .signedOut,
                title: "Sign in to Codex CLI",
                detail: "Codex CLI is installed but not signed in, so it couldn't answer. Your question is still in the box — send it again once you're in.",
                steps: ["Press **Sign in** — Terminal opens and runs `codex login`.",
                        "Finish signing in with ChatGPT in your browser.",
                        "Glance notices on its own — or press **Try again**."],
                copyCommand: "codex login",
                terminalAction: TerminalAction(label: "Sign in", command: "\(q) login"),
                helpURL: codexGuide)
        }
    }
}
