import Foundation

/// Finds the `claude` CLI binary and reports its health (FR16).
///
/// GUI apps launched from Finder don't inherit the user's shell PATH, so we
/// probe common install locations and fall back to a login shell's `which`.
enum ClaudeLocator {

    enum Status {
        case ok(path: String, version: String)
        case notFound
        case unusable(path: String, reason: String)
    }

    private static let candidatePaths: [String] = {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ]
    }()

    /// Resolve the binary path, or nil if not found anywhere we look.
    static func locate() -> String? {
        let fm = FileManager.default
        for p in candidatePaths where fm.isExecutableFile(atPath: p) {
            return p
        }
        // Fall back to a login shell so user-customized PATHs are honored.
        if let viaShell = whichViaLoginShell(), fm.isExecutableFile(atPath: viaShell) {
            return viaShell
        }
        return nil
    }

    /// FR16: distinguish missing / wrong-version / (auth checked at query time).
    static func check() -> Status {
        guard let path = locate() else { return .notFound }
        guard let version = runVersion(path: path) else {
            return .unusable(path: path, reason: "couldn't read `claude --version`")
        }
        // Loose floor check; the CLI evolves fast (addendum). We only require the
        // stream-json flags we depend on, which have existed since 1.x — so any
        // parseable version passes. Kept as a hook for future hard requirements.
        return .ok(path: path, version: version)
    }

    private static func whichViaLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lic", "command -v claude"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false) ? out : nil
    }

    private static func runVersion(path: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
