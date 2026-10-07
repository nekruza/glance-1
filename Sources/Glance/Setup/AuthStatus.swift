import Foundation

/// Asks the provider CLI whether it's signed in, using its own status command
/// (`claude auth status --json`, `codex login status`): local, no network, no
/// model call. Used to confirm a sign-in before dropping the setup card.
enum AuthStatus {

    /// True/false when the CLI answered; nil when it couldn't be run.
    static func check(kind: AskBackendKind, binaryPath: String) async -> Bool? {
        await Task.detached(priority: .userInitiated) {
            let args = kind == .claude ? ["auth", "status", "--json"] : ["login", "status"]
            guard let (code, output) = run(binaryPath, args) else { return nil }
            return kind == .claude ? parseClaude(output) : parseCodex(exitCode: code, output: output)
        }.value
    }

    /// `{"loggedIn": true, …}`
    static func parseClaude(_ json: String) -> Bool? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = object["loggedIn"] as? Bool else { return nil }
        return loggedIn
    }

    /// Exit 0 + "Logged in using ChatGPT"; anything else is signed out.
    static func parseCodex(exitCode: Int32, output: String) -> Bool? {
        let text = output.lowercased()
        return exitCode == 0 && text.contains("logged in") && !text.contains("not logged in")
    }

    private static func run(_ path: String, _ args: [String]) -> (Int32, String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
