import Foundation

/// Drives one Claude CLI process per overlay session (FR14).
///
/// Model: a single persistent `claude -p --input-format stream-json` process.
/// The first question ships the screenshot inline as a base64 image block, so
/// the answer comes back in one turn with no Read-tool permission prompt.
/// Follow-ups (FR12) are extra user-message lines on the same stdin — the live
/// process keeps conversation context (verified against claude 2.1.197).
///
/// Warm path (FR15): `startWarm()` pre-spawns on hotkey-down so process start
/// and auth overlap with the user typing the question.
final class ClaudeBackend {

    enum Event {
        case token(String)          // FR11 incremental text
        case completed              // turn finished
        case failed(String)         // FR13/FR16 user-facing message
    }

    /// FR13 backend timeout ([ASSUMPTION] 30 s to first token).
    var firstTokenTimeout: TimeInterval = 30

    private let binaryPath: String
    private let workingDir: URL
    /// Whether workingDir is our throwaway temp dir (cleaned up on shutdown)
    /// as opposed to a resumed session's original project dir.
    private let ownsWorkingDir: Bool
    /// Claude session UUID to resume: seeded by the History feature, then kept
    /// up to date from the stream so a respawn (process died between overlay
    /// summons) continues the same conversation instead of losing context.
    private var resumeSessionId: String?

    /// Extra system-prompt text appended to the session (V2: task-creation
    /// protocol for the ask overlay).
    var appendSystemPrompt: String?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer = Data()
    private var didSendFirstMessage = false

    private var currentHandler: ((Event) -> Void)?
    private var sawTokenThisTurn = false
    private var timeoutWork: DispatchWorkItem?

    private let ioQueue = DispatchQueue(label: "com.h57q3wq0c.glance.backend")

    init(binaryPath: String, resumeSessionId: String? = nil, resumeCwd: String? = nil) {
        self.binaryPath = binaryPath
        self.resumeSessionId = resumeSessionId

        // Resume needs the session's original cwd — the CLI keys its session
        // store by project directory. Recreate it if it's gone (temp dirs).
        if resumeSessionId != nil, let cwd = resumeCwd {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: cwd, isDirectory: &isDir) {
                try? fm.createDirectory(atPath: cwd, withIntermediateDirectories: true)
                _ = fm.fileExists(atPath: cwd, isDirectory: &isDir)
            }
            if isDir.boolValue {
                self.workingDir = URL(fileURLWithPath: cwd, isDirectory: true)
                self.ownsWorkingDir = false
                return
            }
        }

        // Neutral cwd: a private temp dir so we don't inherit a project's
        // CLAUDE.md / hooks (keeps latency and behavior predictable).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.workingDir = dir
        self.ownsWorkingDir = true
    }

    // MARK: - Lifecycle

    /// Pre-spawn the process (FR15 warm path). Idempotent.
    func startWarm() {
        ioQueue.async { [weak self] in self?.spawnIfNeeded() }
    }

    private func spawnIfNeeded() {
        guard process == nil else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose"
        ]
        if let id = resumeSessionId {
            args += ["--resume", id]
        }
        if let sys = appendSystemPrompt, !sys.isEmpty {
            args += ["--append-system-prompt", sys]
        }
        proc.arguments = args
        proc.currentDirectoryURL = workingDir

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = Pipe() // swallow; failures surface via result/exit

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ioQueue.async { self?.ingest(data) }
        }

        proc.terminationHandler = { [weak self] p in
            self?.ioQueue.async { self?.handleExit(p) }
        }

        do {
            try proc.run()
        } catch {
            emit(.failed("Couldn't launch Claude CLI: \(error.localizedDescription)"))
            return
        }
        self.process = proc
        self.stdinPipe = inPipe
    }

    /// Ask a question. First call includes the screenshot; later calls are
    /// follow-ups on the same session (FR10, FR12).
    func ask(question: String, imagePNG: Data?, onEvent: @escaping (Event) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.spawnIfNeeded()
            self.currentHandler = onEvent
            self.sawTokenThisTurn = false
            self.startTimeout()

            // Attach whatever image the caller passed (may be nil for text-only,
            // or a fresh screenshot on a follow-up). The caller decides.
            self.didSendFirstMessage = true
            let line = Self.userMessageJSON(text: question, imagePNG: imagePNG)
            guard let handle = self.stdinPipe?.fileHandleForWriting,
                  let payload = (line + "\n").data(using: .utf8) else {
                self.emit(.failed("Backend not ready."))
                return
            }
            do {
                try handle.write(contentsOf: payload)
            } catch {
                self.emit(.failed("Couldn't send question to Claude CLI."))
            }
        }
    }

    /// End the session (FR4 dismissal, FR9 cleanup). Terminates the process and
    /// drops the in-memory screenshot bytes.
    func shutdown() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.timeoutWork?.cancel()
            self.currentHandler = nil
            if let p = self.process, p.isRunning {
                self.stdinPipe?.fileHandleForWriting.closeFile()
                p.terminate()
            }
            self.process = nil
            self.stdinPipe = nil
            self.stdoutBuffer.removeAll()
            self.didSendFirstMessage = false
            if self.ownsWorkingDir {
                try? FileManager.default.removeItem(at: self.workingDir)
            }
        }
    }

    // MARK: - Stream handling (ioQueue)

    private func ingest(_ data: Data) {
        stdoutBuffer.append(data)
        // Split complete NDJSON lines on \n.
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<nl]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard !lineData.isEmpty else { continue }
            handleLine(Data(lineData))
        }
    }

    private func handleLine(_ lineData: Data) {
        guard let line = try? JSONDecoder().decode(StreamLine.self, from: lineData) else { return }

        if let sid = line.sessionId { resumeSessionId = sid }

        if let text = line.streamedText, !text.isEmpty {
            if !sawTokenThisTurn {
                sawTokenThisTurn = true
                timeoutWork?.cancel() // first token arrived (FR13)
            }
            emit(.token(text))
            return
        }

        if line.isResult {
            if line.isError == true {
                emit(.failed(Self.friendlyError(from: line.result)))
            } else {
                emit(.completed)
            }
        }
    }

    private func handleExit(_ p: Process) {
        // A terminated process we already replaced (timeout → shutdown →
        // respawn) must not clobber the live one's state.
        guard p === process else { return }
        // If the process dies mid-turn, surface it rather than spin (FR13/FR16).
        timeoutWork?.cancel()
        if currentHandler != nil {
            emit(.failed("Claude CLI exited unexpectedly (status \(p.terminationStatus))."))
        }
        process = nil
        stdinPipe = nil
    }

    private func startTimeout() {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.sawTokenThisTurn else { return }
            self.emit(.failed("Claude didn't respond within \(Int(self.firstTokenTimeout))s."))
            self.shutdown()
        }
        timeoutWork = work
        ioQueue.asyncAfter(deadline: .now() + firstTokenTimeout, execute: work)
    }

    private func emit(_ event: Event) {
        let handler = currentHandler
        // On completion/failure the turn is over; keep handler for follow-ups
        // only after `completed`.
        switch event {
        case .failed:
            currentHandler = nil
        case .completed, .token:
            break
        }
        DispatchQueue.main.async { handler?(event) }
    }

    // MARK: - JSON construction

    private static func userMessageJSON(text: String, imagePNG: Data?) -> String {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if let png = imagePNG {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/png",
                    "data": png.base64EncodedString()
                ]
            ])
        }
        let msg: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: msg)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// FR16: map raw CLI errors to specific, actionable messages.
    private static func friendlyError(from raw: String?) -> String {
        let text = (raw ?? "").lowercased()
        if text.contains("logged in") || text.contains("authenticat") ||
           text.contains("login") || text.contains("unauthorized") || text.contains("api key") {
            return "Claude CLI isn't authenticated. Run `claude` in a terminal and sign in, then try again."
        }
        if text.contains("usage limit") || text.contains("rate limit") || text.contains("quota") {
            return "Claude usage limit reached. Try again later (this draws from your Pro/Max quota)."
        }
        if let raw, !raw.isEmpty { return "Claude error: \(raw)" }
        return "Claude returned an error."
    }
}
