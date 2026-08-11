import Foundation

/// One-shot health check for the Settings "Test" button: does the selected
/// backend actually respond, and how fast. Independent of the streaming overlay path.
enum BackendTester {

    struct Success { let latency: TimeInterval; let reply: String }

    enum Outcome { case success(Success); case failure(String) }

    /// Runs a trivial prompt with a hard timeout. Calls back on the main queue.
    static func test(kind: AskBackendKind = .claude,
                     timeout: TimeInterval = 30,
                     completion: @escaping (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let path: String
            let arguments: [String]
            switch kind {
            case .claude:
                let status = ClaudeLocator.check()
                guard case .ok(let locatedPath, _) = status else {
                    finish(completion, .failure(message(for: status)))
                    return
                }
                path = locatedPath
                arguments = ["-p", "Reply with exactly: OK"]
            case .codex:
                let status = CodexLocator.check()
                guard case .ok(let locatedPath, _) = status else {
                    finish(completion, .failure(message(for: kind, status: status)))
                    return
                }
                path = locatedPath
                arguments = ["exec", "--skip-git-repo-check", "Reply with exactly: OK"]
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = arguments
            proc.currentDirectoryURL = FileManager.default.temporaryDirectory
            let out = Pipe(), err = Pipe()
            proc.standardOutput = out
            proc.standardError = err

            let start = Date()
            do { try proc.run() } catch {
                finish(completion, .failure("Couldn't launch \(kind.rawValue.capitalized): \(error.localizedDescription)"))
                return
            }

            // Enforce timeout without blocking on a possibly-hung child.
            let deadline = DispatchTime.now() + timeout
            let queue = DispatchQueue.global()
            let timer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
            queue.asyncAfter(deadline: deadline, execute: timer)

            proc.waitUntilExit()
            timer.cancel()
            let elapsed = Date().timeIntervalSince(start)

            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: outData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if proc.terminationStatus == 0 && !stdout.isEmpty {
                finish(completion, .success(Success(latency: elapsed, reply: stdout)))
            } else {
                let detail = stderr.isEmpty ? "exit \(proc.terminationStatus)" : stderr
                finish(completion, .failure(friendly(detail, kind: kind)))
            }
        }
    }

    private static func finish(_ completion: @escaping (Outcome) -> Void,
                               _ result: Outcome) {
        DispatchQueue.main.async { completion(result) }
    }

    static func message(for status: ClaudeLocator.Status) -> String {
        switch status {
        case .notFound: return "Claude CLI not found. Install it from claude.com/code."
        case .unusable(let path, let reason): return "Found at \(path) but unusable: \(reason)."
        case .ok: return ""
        }
    }

    static func message(for kind: AskBackendKind, status: CodexLocator.Status) -> String {
        switch status {
        case .notFound: return "Codex CLI not found. Install it and run `codex` to sign in."
        case .unusable(let path, let reason): return "Found at \(path) but unusable: \(reason)."
        case .ok: return ""
        }
    }

    private static func friendly(_ raw: String, kind: AskBackendKind) -> String {
        let t = raw.lowercased()
        if t.contains("login") || t.contains("authenticat") || t.contains("unauthorized") || t.contains("api key") {
            return "Not authenticated. Run `\(kind.rawValue)` in a terminal and sign in."
        }
        if t.contains("usage limit") || t.contains("rate limit") || t.contains("quota") {
            return "Usage limit reached (Pro/Max quota)."
        }
        return "\(kind.rawValue.capitalized) error: \(raw)"
    }
}
