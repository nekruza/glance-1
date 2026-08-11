import Foundation

/// Runs non-interactive Claude CLI prompts behind the shared automation boundary.
final class ClaudeAutomationProvider: AutomationProvider {
    let descriptor: AutomationProviderDescriptor

    private let binaryPath: String
    private let runner = AutomationOneShotRunner(label: "com.glance.automation.claude")

    init(binaryPath: String, version: String) {
        self.binaryPath = binaryPath
        descriptor = AutomationProviderDescriptor(kind: .claude, version: version)
    }

    @discardableResult
    func runText(_ request: AutomationRequest,
                 onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        var arguments = ["-p"]
        if let model = request.model {
            arguments += ["--model", model]
        }
        arguments.append(request.prompt)

        return runner.run(
            executablePath: binaryPath,
            arguments: arguments,
            standardInput: nil,
            workingDirectory: request.workingDirectory,
            timeout: request.timeout,
            launchFailurePrefix: "Couldn't launch Claude CLI",
            decode: Self.decode,
            onEvent: onEvent
        )
    }

    @discardableResult
    func startRun(_ request: AutomationRunRequest,
                  onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        runText(AutomationRequest(prompt: request.prompt, model: request.model,
                                  workingDirectory: request.workingDirectory), onEvent: onEvent)
    }

    @discardableResult
    func runComposio(_ request: ComposioAutomationRequest, token: String,
                     onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        runText(AutomationRequest(prompt: request.prompt, timeout: request.timeout), onEvent: onEvent)
    }

    func cancelAll() {
        runner.cancelAll()
    }

    private static func decode(_ output: Data, _ errors: Data, _ status: Int32) -> [AutomationEvent] {
        guard status == 0 else {
            return [.failed(failureMessage(errors, fallback: "Claude CLI exited unexpectedly (status \(status))."))]
        }

        var events: [AutomationEvent] = []
        if let text = String(data: output, encoding: .utf8), !text.isEmpty {
            events.append(.text(text))
        }
        events.append(.completed)
        return events
    }

    private static func failureMessage(_ errors: Data, fallback: String) -> String {
        let message = String(data: errors, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }
}

/// Owns each process through exit and both pipe drains. Blocking reads happen on
/// separate queues so a chatty child cannot fill stdout or stderr and deadlock.
final class AutomationOneShotRunner {
    typealias Decoder = (_ output: Data, _ errors: Data, _ status: Int32) -> [AutomationEvent]

    private final class CallbackGate {
        private let lock = NSLock()
        private var cancelled = false

        func invalidate() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isValid: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !cancelled
        }
    }

    private final class RunState {
        let id: UUID
        let gate: CallbackGate
        let onEvent: (AutomationEvent) -> Void
        let decode: Decoder
        var process: Process?
        var output: Data?
        var errors: Data?
        var terminationStatus: Int32?
        var timeoutWork: DispatchWorkItem?
        var forceKillWork: DispatchWorkItem?
        var terminalSettled = false
        var callbackDeliveryQueued = false
        var stopRequested = false

        init(id: UUID, gate: CallbackGate, decode: @escaping Decoder,
             onEvent: @escaping (AutomationEvent) -> Void) {
            self.id = id
            self.gate = gate
            self.decode = decode
            self.onEvent = onEvent
        }
    }

    private let queue: DispatchQueue
    private let readerQueue = DispatchQueue(label: "com.glance.automation.pipe-reader",
                                            qos: .utility, attributes: .concurrent)
    private let gateLock = NSLock()
    private var gates: [UUID: CallbackGate] = [:]
    private var runs: [UUID: RunState] = [:]

    init(label: String) {
        queue = DispatchQueue(label: label)
    }

    @discardableResult
    func run(executablePath: String, arguments: [String], standardInput: Data?,
             workingDirectory: URL?, timeout: TimeInterval,
             launchFailurePrefix: String, decode: @escaping Decoder,
             onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        let id = UUID()
        let gate = CallbackGate()
        gateLock.lock()
        gates[id] = gate
        gateLock.unlock()

        queue.async { [weak self] in
            self?.launch(id: id, gate: gate, executablePath: executablePath,
                         arguments: arguments, standardInput: standardInput,
                         workingDirectory: workingDirectory, timeout: timeout,
                         launchFailurePrefix: launchFailurePrefix, decode: decode,
                         onEvent: onEvent)
        }

        return AutomationCancellation { [weak self, gate] in
            gate.invalidate()
            self?.queue.async { [weak self] in self?.cancel(id: id) }
        }
    }

    func cancelAll() {
        gateLock.lock()
        let currentGates = Array(gates.values)
        gateLock.unlock()
        currentGates.forEach { $0.invalidate() }

        queue.async { [weak self] in
            guard let self else { return }
            for id in Array(self.runs.keys) {
                self.cancel(id: id)
            }
        }
    }

    private func launch(id: UUID, gate: CallbackGate, executablePath: String,
                        arguments: [String], standardInput: Data?, workingDirectory: URL?,
                        timeout: TimeInterval, launchFailurePrefix: String,
                        decode: @escaping Decoder,
                        onEvent: @escaping (AutomationEvent) -> Void) {
        guard gate.isValid else {
            removeGate(id)
            return
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = standardInput == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let state = RunState(id: id, gate: gate, decode: decode, onEvent: onEvent)
        state.process = process
        runs[id] = state

        process.terminationHandler = { [weak self] terminatedProcess in
            self?.queue.async { [weak self] in
                self?.recordTermination(of: id, status: terminatedProcess.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            finish(state, events: [.failed("\(launchFailurePrefix): \(error.localizedDescription)")])
            return
        }

        read(outputPipe.fileHandleForReading, for: id, isStandardError: false)
        read(errorPipe.fileHandleForReading, for: id, isStandardError: true)

        if let inputPipe, let standardInput {
            readerQueue.async {
                defer { try? inputPipe.fileHandleForWriting.close() }
                try? inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
            }
        }

        let timeoutWork = DispatchWorkItem { [weak self] in
            self?.timeout(id: id, after: timeout)
        }
        state.timeoutWork = timeoutWork
        queue.asyncAfter(deadline: .now() + max(0, timeout), execute: timeoutWork)
    }

    private func read(_ handle: FileHandle, for id: UUID, isStandardError: Bool) {
        readerQueue.async { [weak self] in
            let data = (try? handle.readToEnd()) ?? Data()
            try? handle.close()
            self?.queue.async { [weak self] in
                self?.record(data, for: id, isStandardError: isStandardError)
            }
        }
    }

    private func record(_ data: Data, for id: UUID, isStandardError: Bool) {
        guard let state = runs[id] else { return }
        if isStandardError {
            state.errors = data
        } else {
            state.output = data
        }
        finishIfReady(state)
    }

    private func recordTermination(of id: UUID, status: Int32) {
        guard let state = runs[id] else { return }
        state.forceKillWork?.cancel()
        state.forceKillWork = nil
        state.terminationStatus = status
        finishIfReady(state)
    }

    private func finishIfReady(_ state: RunState) {
        guard let output = state.output, let errors = state.errors,
              let status = state.terminationStatus else { return }
        if state.terminalSettled {
            cleanup(state)
        } else {
            finish(state, events: state.decode(output, errors, status))
        }
    }

    private func timeout(id: UUID, after timeout: TimeInterval) {
        guard let state = runs[id], !state.terminalSettled else { return }
        state.terminalSettled = true
        state.timeoutWork?.cancel()
        state.timeoutWork = nil
        deliver([.failed("AI provider didn't respond within \(Int(timeout))s.")], for: state)
        requestStop(state)
    }

    private func cancel(id: UUID) {
        guard let state = runs[id] else {
            removeGate(id)
            return
        }
        state.terminalSettled = true
        state.timeoutWork?.cancel()
        state.timeoutWork = nil
        requestStop(state)
        finishIfReady(state)
    }

    private func finish(_ state: RunState, events: [AutomationEvent]) {
        guard !state.terminalSettled else { return }
        state.terminalSettled = true
        state.timeoutWork?.cancel()
        state.timeoutWork = nil
        deliver(events, for: state)
        cleanup(state)
    }

    private func requestStop(_ state: RunState) {
        guard !state.stopRequested else { return }
        state.stopRequested = true
        guard let process = state.process, process.isRunning else { return }

        process.terminate()
        let work = DispatchWorkItem { [weak self, weak state, weak process] in
            guard let self, let state, let process,
                  self.runs[state.id] === state, process.isRunning else { return }
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        state.forceKillWork = work
        queue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func cleanup(_ state: RunState) {
        guard runs[state.id] === state else { return }
        state.forceKillWork?.cancel()
        state.forceKillWork = nil
        runs[state.id] = nil
        if !state.callbackDeliveryQueued {
            removeGate(state.id)
        }
    }

    private func deliver(_ events: [AutomationEvent], for state: RunState) {
        state.callbackDeliveryQueued = true
        let gate = state.gate
        let onEvent = state.onEvent
        let id = state.id
        DispatchQueue.main.async { [weak self] in
            defer { self?.removeGate(id) }
            for event in events {
                guard gate.isValid else { return }
                onEvent(event)
            }
        }
    }

    private func removeGate(_ id: UUID) {
        gateLock.lock()
        gates[id] = nil
        gateLock.unlock()
    }
}
