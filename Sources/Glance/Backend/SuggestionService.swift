import Foundation

/// Generates follow-up prompt suggestions from the last Q&A using a cheap
/// one-shot `claude -p` call (separate from the conversation session, so the
/// transcript is never polluted).
final class SuggestionService {

    private let binaryPath: String
    private var current: Process?
    private let queue = DispatchQueue(label: "com.h57q3wq0c.glance.suggestions")

    init(binaryPath: String) {
        self.binaryPath = binaryPath
    }

    /// Ask for up to 3 short follow-up prompts. Completion is called on main
    /// with [] on any failure. A newer request cancels the one in flight.
    func suggest(question: String, answer: String, completion: @escaping ([String]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.current?.terminate()

            // Keep the excerpt bounded — suggestions don't need the whole answer.
            let a = String(answer.prefix(4000))
            let prompt = """
            Based on this Q&A, suggest 3 short follow-up questions the user \
            might ask next. Each under 60 characters. Output ONLY the 3 \
            questions, one per line, no numbering, no quotes.

            Q: \(question)
            A: \(a)
            """

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: self.binaryPath)
            proc.arguments = ["-p", "--model", "haiku", prompt]
            proc.currentDirectoryURL = FileManager.default.temporaryDirectory

            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()

            proc.terminationHandler = { p in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                guard p.terminationStatus == 0,
                      let text = String(data: data, encoding: .utf8) else {
                    DispatchQueue.main.async { completion([]) }
                    return
                }
                let lines = text.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && $0.count <= 90 }
                    .prefix(3)
                DispatchQueue.main.async { completion(Array(lines)) }
            }

            do {
                try proc.run()
                self.current = proc
            } catch {
                DispatchQueue.main.async { completion([]) }
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.current?.terminate()
            self?.current = nil
        }
    }
}
