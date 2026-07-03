import Foundation
import Combine

/// Live transcript state shared between the meeting transcriber (producer),
/// the ask overlay's side pane (viewer), and the coordinator (question
/// context). Single shared instance — the transcript is app-global state.
@MainActor
final class TranscriptPanelModel: ObservableObject {

    static let shared = TranscriptPanelModel()

    struct Line: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        let text: String
    }

    /// Side pane visibility (footer toggle next to the gear).
    @Published var isVisible = false
    @Published private(set) var isRecording = false
    @Published private(set) var lines: [Line] = []
    /// In-progress utterance (recognizer partial) — shown italic at the end.
    @Published private(set) var partial: String = ""

    /// Wired by the app delegate to MeetingTranscriber start/stop.
    var startHandler: (() -> Void)?
    var stopHandler: (() -> Void)?

    /// Reader actions (wired by the coordinator). Summarize streams the answer
    /// into the main overlay conversation; extract-tasks reports created count.
    var summarizeHandler: ((MeetingHistory.Entry) -> Void)?
    var extractTasksHandler: ((MeetingHistory.Entry, @escaping (Int) -> Void) -> Void)?

    func toggleRecording() {
        if isRecording { stopHandler?() } else { startHandler?() }
    }

    // MARK: - Producer side (main thread)

    func recordingStarted() {
        lines = []
        partial = ""
        isRecording = true
        isVisible = true
    }

    func recordingStopped() {
        isRecording = false
        if !partial.isEmpty {
            lines.append(Line(at: Date(), text: partial))
            partial = ""
        }
    }

    func append(text: String, at date: Date) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Recognizer restarts can re-finalize the same utterance — drop exact
        // consecutive repeats.
        if let last = lines.last, last.text == t { return }
        lines.append(Line(at: date, text: t))
        partial = ""
    }

    /// Near-duplicate resolution: the transcriber decided the new segment
    /// supersedes the previous one.
    func replaceLast(text: String, at date: Date) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if !lines.isEmpty { lines.removeLast() }
        lines.append(Line(at: date, text: t))
        partial = ""
    }

    func updatePartial(_ text: String) {
        partial = text
    }

    // MARK: - Question context (real-time ask-about-the-call)

    /// Recent transcript for prompt context, capped. Empty when nothing useful.
    func contextExcerpt(maxChars: Int = 6000) -> String {
        var all = lines.map { line in
            let tf = DateFormatter()
            tf.dateFormat = "HH:mm"
            return "[\(tf.string(from: line.at))] \(line.text)"
        }.joined(separator: "\n")
        if !partial.isEmpty { all += "\n[now] \(partial)" }
        guard !all.isEmpty else { return "" }
        return String(all.suffix(maxChars))
    }
}
