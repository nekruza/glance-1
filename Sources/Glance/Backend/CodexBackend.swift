import Foundation

/// Runs one `codex exec --json` process per question and resumes the thread for
/// follow-ups. All process and stream state is confined to `ioQueue`.
final class CodexBackend: AskBackend {
    var firstTokenTimeout: TimeInterval = 30

    private let binaryPath: String
    private let workingDirectory: URL
    private let ioQueue = DispatchQueue(label: "com.h57q3wq0c.glance.codex-backend")

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var threadID: String?
    private var activeImageURL: URL?
    private var currentHandler: ((AskBackendEvent) -> Void)?
    private var pendingTurn: PendingTurn?
    private var sawTokenThisTurn = false
    private var receivedTerminalEvent = false
    private var timeoutWork: DispatchWorkItem?

    init(binaryPath: String) {
        self.binaryPath = binaryPath
        self.workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-codex-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        Self.createPrivateDirectory(at: workingDirectory)
    }

    /// Codex's exec protocol needs a prompt to start, so warming only ensures
    /// the private working directory is ready.
    func startWarm() {
        ioQueue.async { [workingDirectory] in
            Self.createPrivateDirectory(at: workingDirectory)
        }
    }

    func ask(question: String, imagePNG: Data?, onEvent: @escaping (AskBackendEvent) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            if self.process != nil, self.currentHandler == nil, self.pendingTurn == nil {
                self.pendingTurn = PendingTurn(question: question, imagePNG: imagePNG, handler: onEvent)
                return
            }
            guard self.process == nil, self.currentHandler == nil, self.pendingTurn == nil else {
                DispatchQueue.main.async {
                    onEvent(.failed("Codex is still answering the previous question."))
                }
                return
            }

            self.beginTurn(question: question, imagePNG: imagePNG, onEvent: onEvent)
        }
    }

    private func beginTurn(question: String, imagePNG: Data?, onEvent: @escaping (AskBackendEvent) -> Void) {
        Self.createPrivateDirectory(at: workingDirectory)
        currentHandler = onEvent
        sawTokenThisTurn = false
        receivedTerminalEvent = false
        stdoutBuffer.removeAll(keepingCapacity: true)
        stderrBuffer.removeAll(keepingCapacity: true)

        do {
            activeImageURL = try writeImage(imagePNG)
            try launch(question: question)
            startTimeout()
        } catch {
            removeActiveImage()
            emit(.failed("Couldn't launch Codex CLI: \(error.localizedDescription)"))
            resetProcessState()
        }
    }

    func shutdown() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.timeoutWork?.cancel()
            self.timeoutWork = nil
            self.currentHandler = nil
            self.pendingTurn = nil
            self.removeActiveImage()
            self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
            if let process = self.process, process.isRunning {
                process.terminate()
            }
            self.resetProcessState()
            try? FileManager.default.removeItem(at: self.workingDirectory)
        }
    }

    deinit {
        timeoutWork?.cancel()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        if let activeImageURL { try? FileManager.default.removeItem(at: activeImageURL) }
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    // MARK: - Process lifecycle (ioQueue)

    private func launch(question: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)

        var arguments = ["exec"]
        if let threadID {
            arguments += ["resume", threadID]
        }
        arguments += ["--json", "--skip-git-repo-check"]
        if let activeImageURL {
            arguments += ["--image", activeImageURL.path]
        }
        arguments.append(question)
        proc.arguments = arguments
        proc.currentDirectoryURL = workingDirectory

        let output = Pipe()
        let errors = Pipe()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = output
        proc.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self, weak proc] handle in
            guard let proc else { return }
            self?.ioQueue.async { [weak self] in
                guard let self, proc === self.process else { return }
                let data = handle.availableData
                if !data.isEmpty { self.ingest(data, from: proc) }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self, weak proc] handle in
            guard let proc else { return }
            self?.ioQueue.async { [weak self] in
                guard let self, proc === self.process else { return }
                let data = handle.availableData
                if !data.isEmpty { self.stderrBuffer.append(data) }
            }
        }
        proc.terminationHandler = { [weak self] terminatedProcess in
            self?.ioQueue.async { [weak self] in self?.handleExit(terminatedProcess) }
        }

        process = proc
        stdoutPipe = output
        stderrPipe = errors
        do {
            try proc.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            resetProcessState()
            throw error
        }
    }

    private func ingest(_ data: Data, from sourceProcess: Process) {
        guard sourceProcess === process else { return }
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[..<newline]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
            handle(line)
        }
    }

    private func handle(_ line: String) {
        guard let event = try? CodexStreamEvent.decode(line) else { return }
        switch event {
        case let .threadStarted(id):
            threadID = id
        case let .token(text):
            guard !text.isEmpty else { return }
            if !sawTokenThisTurn {
                sawTokenThisTurn = true
                timeoutWork?.cancel()
            }
            emit(.token(text))
        case .completed:
            receivedTerminalEvent = true
            timeoutWork?.cancel()
            timeoutWork = nil
            removeActiveImage()
            emit(.completed)
        case let .failed(message):
            receivedTerminalEvent = true
            timeoutWork?.cancel()
            timeoutWork = nil
            removeActiveImage()
            emit(.failed(Self.friendlyError(message)))
            if let process, process.isRunning { process.terminate() }
        case .ignored:
            break
        }
    }

    private func handleExit(_ terminatedProcess: Process) {
        guard terminatedProcess === process else { return }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if let trailingOutput = stdoutPipe?.fileHandleForReading.readDataToEndOfFile(),
           !trailingOutput.isEmpty {
            ingest(trailingOutput, from: terminatedProcess)
        }
        if let trailingErrors = stderrPipe?.fileHandleForReading.readDataToEndOfFile(),
           !trailingErrors.isEmpty {
            stderrBuffer.append(trailingErrors)
        }

        if !stdoutBuffer.isEmpty,
           let trailingLine = String(data: stdoutBuffer, encoding: .utf8),
           !trailingLine.isEmpty {
            stdoutBuffer.removeAll()
            handle(trailingLine)
        }

        timeoutWork?.cancel()
        timeoutWork = nil
        removeActiveImage()
        if !receivedTerminalEvent, currentHandler != nil {
            let stderr = String(data: stderrBuffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let stderr, !stderr.isEmpty {
                emit(.failed(Self.friendlyError(stderr)))
            } else {
                emit(.failed("Codex CLI exited unexpectedly (status \(terminatedProcess.terminationStatus))."))
            }
        }
        let nextTurn = pendingTurn
        pendingTurn = nil
        resetProcessState()
        if let nextTurn {
            beginTurn(question: nextTurn.question, imagePNG: nextTurn.imagePNG, onEvent: nextTurn.handler)
        }
    }

    private func resetProcessState() {
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdoutBuffer.removeAll()
        stderrBuffer.removeAll()
        receivedTerminalEvent = false
    }

    // MARK: - Timeout and events

    private func startTimeout() {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.sawTokenThisTurn, self.currentHandler != nil else { return }
            self.removeActiveImage()
            self.emit(.failed("Codex didn't respond within \(Int(self.firstTokenTimeout))s."))
            if let process = self.process, process.isRunning { process.terminate() }
        }
        timeoutWork = work
        ioQueue.asyncAfter(deadline: .now() + firstTokenTimeout, execute: work)
    }

    private func emit(_ event: AskBackendEvent) {
        let handler = currentHandler
        switch event {
        case .completed, .failed:
            currentHandler = nil
        case .token:
            break
        }
        DispatchQueue.main.async { handler?(event) }
    }

    // MARK: - Private files

    private static func createPrivateDirectory(at url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func writeImage(_ data: Data?) throws -> URL? {
        guard let data else { return nil }
        let url = workingDirectory.appendingPathComponent("attachment-\(UUID().uuidString).png")
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func removeActiveImage() {
        guard let url = activeImageURL else { return }
        try? FileManager.default.removeItem(at: url)
        activeImageURL = nil
    }

    private static func friendlyError(_ raw: String) -> String {
        let normalized = raw.lowercased()
        if normalized.contains("login") || normalized.contains("authenticat") ||
           normalized.contains("unauthorized") || normalized.contains("api key") {
            return "Codex CLI isn't authenticated. Run `codex` in a terminal and sign in, then try again."
        }
        if normalized.contains("usage limit") || normalized.contains("rate limit") ||
           normalized.contains("quota") {
            return "Codex usage limit reached. Try again later."
        }
        return raw.hasPrefix("Codex") ? raw : "Codex error: \(raw)"
    }

    private struct PendingTurn {
        let question: String
        let imagePNG: Data?
        let handler: (AskBackendEvent) -> Void
    }
}
