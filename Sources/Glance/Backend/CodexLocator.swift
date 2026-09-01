import Foundation

/// Finds the `codex` CLI binary and reports its health.
///
/// GUI apps launched from Finder don't inherit the user's shell PATH, so we
/// probe common install locations and fall back to a login shell's `command -v`.
enum CodexLocator {

    enum Status {
        case ok(path: String, version: String)
        case notFound
        case unusable(path: String, reason: String)
    }

    private static let candidatePaths: [String] = {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]
    }()

    static func locate() -> String? {
        let fm = FileManager.default
        for path in candidatePaths where fm.isExecutableFile(atPath: path) {
            return path
        }
        if let viaShell = whichViaLoginShell(), fm.isExecutableFile(atPath: viaShell) {
            return viaShell
        }
        return nil
    }

    static func check() -> Status {
        guard let path = locate() else { return .notFound }
        guard let version = runVersion(path: path) else {
            return .unusable(path: path, reason: "couldn't read `codex --version`")
        }
        return .ok(path: path, version: version)
    }

    private static func whichViaLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lic", "command -v codex"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (output?.isEmpty == false) ? output : nil
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
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
