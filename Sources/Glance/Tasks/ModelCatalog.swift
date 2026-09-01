import Foundation
import Darwin

/// Resolves what the CLI's model aliases (default/haiku/sonnet/opus) actually
/// map to, so the task model menu can show real names ("Opus 4.8"). Probing
/// requires a real (tiny) generation per alias, so results are cached in
/// UserDefaults keyed by CLI version — re-probed only when the CLI updates.
@MainActor
final class ModelCatalog: ObservableObject {

    static let shared = ModelCatalog()

    /// alias → human name ("sonnet" → "Sonnet 5"). Empty until resolved.
    @Published private(set) var names: [String: String] = [:]

    private static let cacheKey = "models.aliasNames"
    private static let versionKey = "models.cliVersion"
    private var probing = false
    private var probeGeneration: UInt = 0
    private var probeOperation: ProbeOperation?

    private final class ProbeOperation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var process: Process?

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func prepare(_ process: Process) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return false }
            self.process = process
            return true
        }

        func didLaunch(_ process: Process) {
            lock.lock()
            let shouldStop = cancelled && self.process === process
            lock.unlock()
            if shouldStop { Self.stop(process) }
        }

        func didFinish(_ process: Process) {
            lock.lock()
            if self.process === process { self.process = nil }
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let process = self.process
            lock.unlock()
            if let process { Self.stop(process) }
        }

        private static func stop(_ process: Process) {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [weak process] in
                guard let process, process.isRunning else { return }
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    func displayName(for alias: String?) -> String? {
        names[alias ?? "default"]
    }

    static func choices(for provider: AskBackendKind) -> [AutomationModelChoice] {
        AutomationProviderDescriptor(kind: provider, version: "").modelChoices
    }

    static func label(for choice: AutomationModelChoice, provider: AskBackendKind) -> String {
        switch choice {
        case .automatic:
            return "Auto — \(provider.displayName) default"
        case .haiku, .sonnet, .opus:
            return choice.rawValue
        }
    }

    /// UI selection for a persisted model. Unsupported aliases are presented
    /// as automatic without mutating the persisted value.
    static func presentedChoice(for storedModel: String?, provider: AskBackendKind)
        -> AutomationModelChoice {
        guard let storedModel,
              let choice = AutomationModelChoice(rawValue: storedModel),
              choices(for: provider).contains(choice)
        else { return .automatic }
        return choice
    }

    /// Codex currently has no named model menu, so selecting its only visible
    /// choice must retain a Claude alias for a later provider switch.
    static func storedModel(afterSelecting choice: AutomationModelChoice,
                            current: String?, provider: AskBackendKind) -> String? {
        guard provider == .claude else { return current }
        return choice == .automatic ? nil : choice.rawValue
    }

    /// Provider-aware entry point used once AppCoordinator migrates in Task 6.
    func refresh(for provider: AskBackendKind, binaryPath: String, cliVersion: String) {
        guard provider == .claude else {
            cancelProbes()
            return
        }
        refresh(binaryPath: binaryPath, cliVersion: cliVersion)
    }

    /// Invalidate probes immediately, including switches to an unavailable
    /// provider that has no binary path to pass to `refresh`.
    func providerDidChange() {
        cancelProbes()
    }

    /// Claude compatibility entry point until AppCoordinator migrates in Task 6.
    func refresh(binaryPath: String, cliVersion: String) {
        cancelProbes()
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.versionKey) == cliVersion,
           let cached = defaults.dictionary(forKey: Self.cacheKey) as? [String: String],
           !cached.isEmpty {
            names = cached
            return
        }
        probing = true
        let operation = ProbeOperation()
        probeOperation = operation
        let generation = probeGeneration

        Task.detached(priority: .utility) {
            var resolved: [String: String] = [:]
            for alias in ["default", "haiku", "sonnet", "opus"] {
                guard !operation.isCancelled else { break }
                if let id = Self.probe(binaryPath: binaryPath,
                                       alias: alias == "default" ? nil : alias,
                                       operation: operation) {
                    resolved[alias] = Self.prettify(id)
                }
            }
            await MainActor.run { [resolved] in
                guard self.probeGeneration == generation,
                      self.probeOperation === operation,
                      !operation.isCancelled else { return }
                self.probeOperation = nil
                self.probing = false
                guard !resolved.isEmpty else {
                    return
                }
                self.names = resolved
                UserDefaults.standard.set(resolved, forKey: Self.cacheKey)
                UserDefaults.standard.set(cliVersion, forKey: Self.versionKey)
            }
        }
    }

    private func cancelProbes() {
        probeGeneration &+= 1
        probing = false
        let operation = probeOperation
        probeOperation = nil
        operation?.cancel()
    }

    /// One minimal generation; the result JSON's modelUsage names the model id.
    nonisolated private static func probe(binaryPath: String, alias: String?,
                                          operation: ProbeOperation) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        var args = ["-p", "--output-format", "json"]
        if let alias { args += ["--model", alias] }
        args.append("Reply with exactly: ok")
        proc.arguments = args
        proc.currentDirectoryURL = FileManager.default.temporaryDirectory
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard operation.prepare(proc) else { return nil }
        defer { operation.didFinish(proc) }
        do {
            try proc.run()
            operation.didLaunch(proc)
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard !operation.isCancelled, proc.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = obj["modelUsage"] as? [String: Any]
        else { return nil }
        return usage.keys.first
    }

    /// "claude-opus-4-8" → "Opus 4.8"; "claude-haiku-4-5-20251001" → "Haiku 4.5".
    nonisolated static func prettify(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        // Drop a trailing date stamp (8 digits).
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        let family = parts.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? id
        let version = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return version.isEmpty ? family : "\(family) \(version)"
    }
}
