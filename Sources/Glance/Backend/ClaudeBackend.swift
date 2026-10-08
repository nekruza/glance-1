import Foundation
import Darwin

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
final class ClaudeBackend: AskBackend {

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

    private var currentHandler: ((AskBackendEvent) -> Void)?
    private var catalogHandler: ((BackendCatalog) -> Void)?
    private var sawTokenThisTurn = false
    /// User messages written whose `result` line hasn't arrived yet.
    private var openTurns = 0
    /// Interrupted turns whose leftover lines (through their `result`, which
    /// the CLI reports as `error_during_execution`) must be dropped.
    private var discardedTurns = 0
    private var timeoutWork: DispatchWorkItem?
    private var shutdownForceKillWork: DispatchWorkItem?
    private var shuttingDown = false
    /// `AskBackendLifecycle` releases a backend immediately after shutdown.
    /// Retain this owner until its child has actually exited.
    private var shutdownKeepAlive: ClaudeBackend?

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
        // CLAUDE.md / hooks (keeps latency and behavior predictable). One per
        // backend: a replaced backend deletes its dir on shutdown, which must
        // never be the dir its successor launches in.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.workingDir = dir
        self.ownsWorkingDir = true
    }

    // MARK: - Lifecycle

    func configure(systemPrompt: String) {
        appendSystemPrompt = systemPrompt
    }

    func onCatalog(_ handler: @escaping (BackendCatalog) -> Void) {
        ioQueue.async { [weak self] in self?.catalogHandler = handler }
    }

    /// Pre-spawn the process (FR15 warm path). Idempotent.
    func startWarm() {
        ioQueue.async { [weak self] in self?.spawnIfNeeded() }
    }

    private func spawnIfNeeded() {
        guard process == nil, !shuttingDown else { return }

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
        // Launching in a missing dir fails outright; the system may have
        // cleaned the temp dir during a long-lived session.
        if ownsWorkingDir {
            try? FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
        }
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

        // Ask for the command catalog up front, as the Agent SDK does on
        // connect: free, ~3 s, and the `/` menu is filled before the first
        // question (the init line only arrives once a message is sent).
        let initialize = #"{"type":"control_request","request_id":"glance-init","request":{"subtype":"initialize"}}"#
        try? inPipe.fileHandleForWriting.write(contentsOf: Data((initialize + "\n").utf8))
    }

    /// Ask a question. First call includes the screenshot; later calls are
    /// follow-ups on the same session (FR10, FR12).
    func ask(question: String, imagePNG: Data?, onEvent: @escaping (AskBackendEvent) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            // Handler first: a failed launch reports why to this question.
            self.currentHandler = onEvent
            self.sawTokenThisTurn = false
            self.spawnIfNeeded()
            guard self.currentHandler != nil else { return } // launch failed, already reported
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
                self.openTurns += 1
            } catch {
                self.emit(.failed("Couldn't send question to Claude CLI."))
            }
        }
    }

    /// Send the CLI's `interrupt` control request — what Esc does in the
    /// terminal. It answers with an `error_during_execution` result for the
    /// stopped turn and then takes follow-ups on the same session.
    func interrupt() {
        ioQueue.async { [weak self] in
            guard let self, self.openTurns > self.discardedTurns,
                  let handle = self.stdinPipe?.fileHandleForWriting else { return }
            self.timeoutWork?.cancel()
            self.timeoutWork = nil
            self.currentHandler = nil
            self.discardedTurns += 1
            let request = #"{"type":"control_request","request_id":"glance-stop-\#(UUID().uuidString)","request":{"subtype":"interrupt"}}"#
            try? handle.write(contentsOf: Data((request + "\n").utf8))
        }
    }

    /// End the session (FR4 dismissal, FR9 cleanup). Terminates the process and
    /// drops the in-memory screenshot bytes.
    func shutdown() {
        ioQueue.async { [self] in
            self.timeoutWork?.cancel()
            self.timeoutWork = nil
            self.currentHandler = nil
            self.shuttingDown = true
            if let p = self.process, p.isRunning {
                self.shutdownKeepAlive = self
                self.stdinPipe?.fileHandleForWriting.closeFile()
                (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
                self.requestShutdown(of: p)
            } else {
                self.process = nil
                self.stdinPipe = nil
                self.finishShutdown()
            }
            self.stdoutBuffer.removeAll()
            self.didSendFirstMessage = false
            self.openTurns = 0
            self.discardedTurns = 0
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

        if let catalog = line.catalog, let handler = catalogHandler {
            DispatchQueue.main.async { handler(catalog) }
        }

        if line.isResult { openTurns = max(openTurns - 1, 0) }
        // Lines still belonging to a turn the user stopped: its partial text,
        // tool runs and the interrupted result never reach the next turn.
        if discardedTurns > 0 {
            if line.isResult { discardedTurns -= 1 }
            return
        }

        // Local commands (/context, /model, /usage…) answer with one whole
        // assistant message and no stream deltas; without this the turn
        // would complete blank.
        if !sawTokenThisTurn, let text = line.successResultText {
            sawTokenThisTurn = true
            timeoutWork?.cancel()
            emit(.commandOutput(text))
        }

        if let event = line.askBackendEvent {
            switch event {
            case .token, .activity:
                // Text or a tool/thinking start: the CLI is alive (FR13). Tool
                // runs (Jira, Slack…) can go well past the timeout before text.
                if !sawTokenThisTurn {
                    sawTokenThisTurn = true
                    timeoutWork?.cancel()
                }
            case .completed, .failed, .model, .commandOutput, .signedOut:
                break
            }
            emit(event)
            return
        }

        if line.isResult, line.isError == true {
            emit(Self.isAuthError(line.result) ? .signedOut : .failed(Self.friendlyError(from: line.result)))
        }
    }

    private func handleExit(_ p: Process) {
        // A terminated process we already replaced (timeout → shutdown →
        // respawn) must not clobber the live one's state.
        guard p === process else { return }
        shutdownForceKillWork?.cancel()
        shutdownForceKillWork = nil
        // If the process dies mid-turn, surface it rather than spin (FR13/FR16).
        // The handler outlives a completed turn, so check a question is still
        // waiting for its result — an idle exit must not fail the last answer.
        timeoutWork?.cancel()
        if currentHandler != nil, openTurns > 0 {
            emit(.failed("Claude CLI exited unexpectedly (status \(p.terminationStatus))."))
        }
        process = nil
        stdinPipe = nil
        openTurns = 0
        discardedTurns = 0
        if shuttingDown { finishShutdown() }
    }

    private func requestShutdown(of process: Process) {
        guard process.isRunning else {
            self.process = nil
            self.stdinPipe = nil
            finishShutdown()
            return
        }
        process.terminate()
        let work = DispatchWorkItem { [weak self, weak process] in
            guard let self, let process, process === self.process,
                  process.isRunning else { return }
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        shutdownForceKillWork = work
        ioQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func finishShutdown() {
        shutdownForceKillWork?.cancel()
        shutdownForceKillWork = nil
        if ownsWorkingDir {
            try? FileManager.default.removeItem(at: workingDir)
        }
        shutdownKeepAlive = nil
    }

    private func startTimeout() {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.sawTokenThisTurn else { return }
            self.emit(.failed("Claude didn't respond within \(Int(self.firstTokenTimeout))s."))
            self.abandonHungProcess()
        }
        timeoutWork = work
        ioQueue.asyncAfter(deadline: .now() + firstTokenTimeout, execute: work)
    }

    /// Kill a CLI that never answered but keep this backend: it stays the
    /// installed one, so `shutdown()` here would fail every later question
    /// with "Backend not ready.". The next ask spawns a fresh CLI, resuming
    /// the session.
    private func abandonHungProcess() {
        guard let hung = process else { return }
        (hung.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        stdinPipe?.fileHandleForWriting.closeFile()
        // Detach first: its exit is then ignored (handleExit checks identity)
        // and nothing it still prints reaches the next turn.
        process = nil
        stdinPipe = nil
        stdoutBuffer.removeAll()
        openTurns = 0
        discardedTurns = 0
        hung.terminate()
        ioQueue.asyncAfter(deadline: .now() + 0.25) { [weak hung] in
            guard let hung, hung.isRunning else { return }
            Darwin.kill(hung.processIdentifier, SIGKILL)
        }
    }

    private func emit(_ event: AskBackendEvent) {
        let handler = currentHandler
        // On completion/failure the turn is over; keep handler for follow-ups
        // only after `completed`.
        switch event {
        case .failed, .signedOut:
            currentHandler = nil
        case .completed, .token, .model, .commandOutput, .activity:
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

    /// "Not logged in · Please run /login", "Invalid API key", 401s…
    static func isAuthError(_ raw: String?) -> Bool {
        let text = (raw ?? "").lowercased()
        return text.contains("logged in") || text.contains("authenticat") ||
            text.contains("login") || text.contains("unauthorized") || text.contains("api key")
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
