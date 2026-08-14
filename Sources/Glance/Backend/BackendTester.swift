import Foundation
import Combine

/// One-shot health check for the Settings "Test" button: does the selected
/// AI provider actually respond, and how fast. Independent of the streaming overlay path.
enum BackendTester {

    struct Success { let latency: TimeInterval; let reply: String }

    enum Outcome { case success(Success); case failure(String) }

    struct Command {
        let executablePath: String
        let arguments: [String]
    }

    private final class TestOperation {
        private let lock = NSLock()
        private var cancellation: AutomationCancellation?
        private var runner: AutomationOneShotRunner?
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func install(runner: AutomationOneShotRunner,
                     cancellation: AutomationCancellation) {
            lock.lock()
            if cancelled {
                lock.unlock()
                cancellation.cancel()
                runner.cancelAll()
                return
            }
            self.runner = runner
            self.cancellation = cancellation
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                return
            }
            cancelled = true
            let cancellation = self.cancellation
            let runner = self.runner
            self.cancellation = nil
            self.runner = nil
            lock.unlock()
            cancellation?.cancel()
            runner?.cancelAll()
        }
    }

    /// Runs a trivial prompt with a hard timeout. Calls back on the main queue.
    @discardableResult
    static func test(kind: AskBackendKind = .claude,
                     timeout: TimeInterval = 30,
                     completion: @escaping (Outcome) -> Void) -> AutomationCancellation {
        let operation = TestOperation()
        DispatchQueue.global(qos: .userInitiated).async {
            guard !operation.isCancelled else { return }
            let command: Command
            switch kind {
            case .claude:
                let status = ClaudeLocator.check()
                guard case .ok(let locatedPath, _) = status else {
                    guard !operation.isCancelled else { return }
                    finish(completion, .failure(message(for: status)))
                    return
                }
                command = Command(executablePath: locatedPath,
                                  arguments: ["-p", "Reply with exactly: OK"])
            case .codex:
                let status = CodexLocator.check()
                guard case .ok(let locatedPath, _) = status else {
                    guard !operation.isCancelled else { return }
                    finish(completion, .failure(message(for: kind, status: status)))
                    return
                }
                command = Command(executablePath: locatedPath,
                                  arguments: ["exec", "--skip-git-repo-check",
                                              "Reply with exactly: OK"])
            }
            start(command: command, kind: kind, timeout: timeout,
                  operation: operation, completion: completion)
        }
        return AutomationCancellation { operation.cancel() }
    }

    /// Testable command-level entry point; production resolves the selected CLI
    /// first and then uses the same owned process lifecycle.
    @discardableResult
    static func test(command: Command, kind: AskBackendKind,
                     timeout: TimeInterval = 30,
                     completion: @escaping (Outcome) -> Void) -> AutomationCancellation {
        let operation = TestOperation()
        start(command: command, kind: kind, timeout: timeout,
              operation: operation, completion: completion)
        return AutomationCancellation { operation.cancel() }
    }

    private static func start(command: Command, kind: AskBackendKind,
                              timeout: TimeInterval, operation: TestOperation,
                              completion: @escaping (Outcome) -> Void) {
        guard !operation.isCancelled else { return }
        let runner = AutomationOneShotRunner(label: "com.glance.backend-test.\(UUID().uuidString)")
        let startedAt = Date()
        let cancellation = runner.run(
            executablePath: command.executablePath,
            arguments: command.arguments,
            standardInput: nil,
            workingDirectory: FileManager.default.temporaryDirectory,
            timeout: timeout,
            launchFailurePrefix: "Couldn't launch \(kind.displayName)",
            decode: { output, errors, status in
                let stdout = String(data: output, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard status == 0, !stdout.isEmpty else {
                    let stderr = String(data: errors, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let detail = stderr.isEmpty ? "exit \(status)" : stderr
                    return [.failed(friendly(detail, kind: kind))]
                }
                return [.text(stdout), .completed]
            },
            timeoutFailure: { _ in "\(kind.displayName) didn't respond before the test timed out." },
            onEvent: { event in
                guard !operation.isCancelled else { return }
                switch event {
                case .text(let reply):
                    finish(completion, .success(Success(
                        latency: Date().timeIntervalSince(startedAt), reply: reply
                    )))
                case .failed(let message):
                    finish(completion, .failure(message))
                case .completed, .sessionID:
                    break
                }
            }
        )
        operation.install(runner: runner, cancellation: cancellation)
    }

    private static func finish(_ completion: @escaping (Outcome) -> Void,
                               _ result: Outcome) {
        DispatchQueue.main.async { completion(result) }
    }

    static func message(for status: ClaudeLocator.Status) -> String {
        switch status {
        case .notFound: return "\(AskBackendKind.claude.displayName) not found. Install it from claude.com/code."
        case .unusable(let path, let reason): return "Found at \(path) but unusable: \(reason)."
        case .ok: return ""
        }
    }

    static func message(for kind: AskBackendKind, status: CodexLocator.Status) -> String {
        switch status {
        case .notFound: return "\(kind.displayName) not found. Install it and run `codex` to sign in."
        case .unusable(let path, let reason): return "Found at \(path) but unusable: \(reason)."
        case .ok: return ""
        }
    }

    static func friendly(_ raw: String, kind: AskBackendKind) -> String {
        let t = raw.lowercased()
        if t.contains("login") || t.contains("authenticat") || t.contains("unauthorized") || t.contains("api key") {
            return "Not authenticated. Run `\(kind.rawValue)` in a terminal and sign in."
        }
        if t.contains("usage limit") || t.contains("rate limit") || t.contains("quota") {
            switch kind {
            case .claude: return "Usage limit reached (Pro/Max quota)."
            case .codex: return "Usage limit reached. Try again later."
            }
        }
        return "\(kind.displayName) error: \(raw)"
    }
}

/// Owns a Settings test operation and makes provider changes a synchronous UI
/// boundary. A cancelled provider callback cannot overwrite the new selection.
@MainActor
final class BackendTestSession: ObservableObject {
    typealias Start = (_ kind: AskBackendKind, _ timeout: TimeInterval,
                       _ completion: @escaping (BackendTester.Outcome) -> Void)
        -> AutomationCancellation

    @Published private(set) var isTesting = false
    @Published private(set) var outcome: BackendTester.Outcome?

    private let run: Start
    private var cancellation: AutomationCancellation?
    private var generation: UInt = 0
    private var kind: AskBackendKind?

    init(run: @escaping Start = { kind, timeout, completion in
        BackendTester.test(kind: kind, timeout: timeout, completion: completion)
    }) {
        self.run = run
    }

    deinit {
        cancellation?.cancel()
    }

    func start(kind: AskBackendKind, timeout: TimeInterval = 30) {
        invalidate(to: kind)
        isTesting = true
        let currentGeneration = generation
        cancellation = run(kind, timeout) { [weak self] outcome in
            guard let self, self.generation == currentGeneration,
                  self.kind == kind else { return }
            self.cancellation = nil
            self.isTesting = false
            self.outcome = outcome
        }
    }

    func providerDidChange(to kind: AskBackendKind) {
        invalidate(to: kind)
    }

    /// Explicit owner-lifecycle boundary for retained settings surfaces. A
    /// reusable window can close without releasing this object, so deinit is
    /// not sufficient to stop its child process or reject a queued callback.
    func cancel() {
        generation &+= 1
        cancellation?.cancel()
        cancellation = nil
        isTesting = false
        outcome = nil
    }

    private func invalidate(to kind: AskBackendKind) {
        self.kind = kind
        cancel()
    }
}
