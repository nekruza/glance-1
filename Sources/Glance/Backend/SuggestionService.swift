import Foundation

/// Generates follow-up prompt suggestions from the last Q&A using a cheap
/// one-shot provider request (separate from the conversation session, so the
/// transcript is never polluted).
final class SuggestionService {

    private final class RequestState {
        var output = ""
        var settled = false
    }

    private let provider: AutomationProvider
    private let lock = NSLock()
    private var currentState: RequestState?
    private var currentCancellation: AutomationCancellation?

    init(provider: AutomationProvider) {
        self.provider = provider
    }

    /// Compatibility bridge until AppCoordinator owns the selected provider
    /// as part of the Task 6 service-bundle migration.
    convenience init(binaryPath: String) {
        self.init(provider: ClaudeAutomationProvider(binaryPath: binaryPath,
                                                     version: "compatibility"))
    }

    /// Ask for up to 3 short follow-up prompts. Completion is called on main
    /// with [] on any failure. A newer request cancels the one in flight.
    func suggest(question: String, answer: String, completion: @escaping ([String]) -> Void) {
        let state = RequestState()
        lock.lock()
        let previous = currentCancellation
        currentState?.settled = true
        currentState = state
        currentCancellation = nil
        lock.unlock()
        previous?.cancel()

        // Keep the excerpt bounded — suggestions don't need the whole answer.
        let a = String(answer.prefix(4000))
        let prompt = """
        Based on this Q&A, suggest 3 short follow-up questions the user \
        might ask next. Each under 60 characters. Output ONLY the 3 \
        questions, one per line, no numbering, no quotes.

        Q: \(question)
        A: \(a)
        """

        let model = provider.descriptor.model(for: .haiku)
        let cancellation = provider.runText(AutomationRequest(prompt: prompt, model: model)) {
            [weak self, state] event in
            self?.handle(event, for: state, completion: completion)
        }

        lock.lock()
        let stillCurrent = currentState === state && !state.settled
        if stillCurrent { currentCancellation = cancellation }
        lock.unlock()
        if !stillCurrent { cancellation.cancel() }
    }

    func cancel() {
        lock.lock()
        let cancellation = currentCancellation
        currentState?.settled = true
        currentState = nil
        currentCancellation = nil
        lock.unlock()
        cancellation?.cancel()
    }

    private func handle(_ event: AutomationEvent, for state: RequestState,
                        completion: @escaping ([String]) -> Void) {
        var result: [String]?
        lock.lock()
        guard currentState === state, !state.settled else {
            lock.unlock()
            return
        }
        switch event {
        case .text(let text):
            state.output += text
        case .completed:
            state.settled = true
            currentState = nil
            currentCancellation = nil
            result = Self.parse(state.output)
        case .failed:
            state.settled = true
            currentState = nil
            currentCancellation = nil
            result = []
        case .sessionID:
            break
        }
        lock.unlock()

        if let result {
            if Thread.isMainThread {
                completion(result)
            } else {
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private static func parse(_ text: String) -> [String] {
        Array(text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 90 }
            .prefix(3))
    }
}
