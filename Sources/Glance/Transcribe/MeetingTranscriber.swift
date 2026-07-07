import AVFoundation
import ScreenCaptureKit
import Speech

/// Granola-style meeting transcription.
///
/// Two audio paths, transcribed independently and merged by time:
///  - "Them": system audio (Meet/Slack/Zoom output) via ScreenCaptureKit —
///    reuses the Screen Recording permission the app already needs.
///  - "Me":   the microphone via AVAudioEngine.
///
/// Recognition is Apple's on-device Speech framework (no audio leaves the
/// machine). On stop, the transcript is written to ~/Documents/Glance Meetings/
/// and summarized into notes via a one-shot `claude -p` call.
/// Debug breadcrumbs → /tmp/glance-meeting.log (NSLog was invisible in the
/// unified log for this app).
func meetingLog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    if let data = line.data(using: .utf8),
       let handle = FileHandle(forWritingAtPath: "/tmp/glance-meeting.log") {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        try? line.write(toFile: "/tmp/glance-meeting.log", atomically: false, encoding: .utf8)
    }
}

/// Mixes the two live audio sources (mic + system) into ONE mono 16 kHz
/// stream for the recognizer. Interleaving unmixed buffers from parallel
/// streams corrupts the audio timeline and produces garbage transcription —
/// they must be summed sample-wise. A 10 Hz drain takes the samples available
/// from both rings (zero-filling the quieter/slower source) so clock drift
/// between the two capture paths can't accumulate.
private final class AudioMixer {

    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converters: [AVAudioFormat: AVAudioConverter] = [:]
    private var systemRing: [Float] = []
    private var micRing: [Float] = []
    private let queue = DispatchQueue(label: "com.h57q3wq0c.glance.mixer")
    private var timer: DispatchSourceTimer?

    var onMixed: ((AVAudioPCMBuffer) -> Void)?

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.drain(final: false) }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync { drain(final: true) }
    }

    func appendSystem(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, let mono = self.convertToMono16k(buffer) else { return }
            self.systemRing.append(contentsOf: mono)
        }
    }

    func appendMic(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, let mono = self.convertToMono16k(buffer) else { return }
            self.micRing.append(contentsOf: mono)
        }
    }

    // queue only ↓

    private func drain(final: Bool) {
        // Emit the max available; the source with fewer samples is zero-padded.
        let n = final ? max(systemRing.count, micRing.count)
                      : max(systemRing.count, micRing.count)
        guard n > 0 else { return }
        var mixed = [Float](repeating: 0, count: n)
        for i in 0..<min(n, systemRing.count) { mixed[i] += systemRing[i] }
        for i in 0..<min(n, micRing.count) { mixed[i] += micRing[i] }
        for i in 0..<n { mixed[i] = max(-1, min(1, mixed[i])) }
        systemRing.removeFirst(min(n, systemRing.count))
        micRing.removeFirst(min(n, micRing.count))

        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                         frameCapacity: AVAudioFrameCount(n)),
              let dst = out.floatChannelData?[0] else { return }
        out.frameLength = AVAudioFrameCount(n)
        mixed.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: n) }
        onMixed?(out)
    }

    private func convertToMono16k(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let sourcePCM: AVAudioPCMBuffer
        if buffer.format == targetFormat {
            sourcePCM = buffer
        } else {
            let converter: AVAudioConverter
            if let cached = converters[buffer.format] {
                converter = cached
            } else if let made = AVAudioConverter(from: buffer.format, to: targetFormat) {
                converters[buffer.format] = made
                converter = made
            } else {
                return nil
            }
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
            var served = false
            var convErr: NSError?
            converter.convert(to: out, error: &convErr) { _, status in
                if served {
                    status.pointee = .noDataNow
                    return nil
                }
                served = true
                status.pointee = .haveData
                return buffer
            }
            guard convErr == nil, out.frameLength > 0 else { return nil }
            sourcePCM = out
        }
        guard let src = sourcePCM.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: src, count: Int(sourcePCM.frameLength)))
    }
}

final class MeetingTranscriber: NSObject, SCStreamOutput, SCStreamDelegate {

    struct Segment {
        let start: Date
        let speaker: String
        let text: String
    }

    private(set) var isRecording = false
    private var startedAt = Date()

    private var stream: SCStream?
    private let engine = AVAudioEngine()
    /// Single recognizer fed by BOTH audio sources. Two concurrent
    /// SFSpeechRecognizer tasks preempt each other (~2 s ping-pong of
    /// "No speech detected"), chopping the transcript to fragments — one
    /// merged stream transcribes coherently at the cost of Me/Them labels.
    private var channel: ChannelRecognizer?
    private let mixer = AudioMixer()

    private var segments: [Segment] = []
    private let segmentLock = NSLock()

    private let audioQueue = DispatchQueue(label: "com.h57q3wq0c.glance.meeting-audio")

    /// Called on main when recording state flips (menu refresh).
    var onStateChange: (() -> Void)?
    /// Fired on main after the transcript file is finalized (AI summary
    /// prepended if one was generated) — carries the notes file URL. Drives
    /// post-meeting action-item extraction.
    var onSummarized: ((URL) -> Void)?
    /// Live feed for the overlay transcript pane (main thread).
    var onLiveSegment: ((Segment) -> Void)?
    var onLiveReplaceLast: ((Segment) -> Void)?
    var onLivePartial: ((String) -> Void)?

    // MARK: - Permissions

    static func requestPermissions(_ completion: @escaping (Bool, String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { auth in
            guard auth == .authorized else {
                DispatchQueue.main.async {
                    completion(false, "Speech recognition not authorized. Enable it in System Settings ▸ Privacy & Security ▸ Speech Recognition.")
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { micOK in
                DispatchQueue.main.async {
                    if !micOK {
                        completion(false, "Microphone access denied. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.")
                    } else if !ScreenCaptureService.hasPermission {
                        completion(false, "Screen Recording permission is required to hear the other side of the call. Grant it in System Settings, then try again.")
                    } else {
                        completion(true, nil)
                    }
                }
            }
        }
    }

    // MARK: - Start / stop

    func start() async throws {
        guard !isRecording else { return }
        segments = []
        startedAt = Date()

        let rec = ChannelRecognizer(speaker: "")
        rec.onSegment = { [weak self] seg in self?.append(seg) }
        rec.onPartial = { [weak self] text in
            DispatchQueue.main.async { self?.onLivePartial?(text) }
        }
        channel = rec
        rec.start()
        mixer.onMixed = { [weak rec] buffer in rec?.append(buffer) }
        mixer.start()

        // System audio via ScreenCaptureKit — video dialed to nothing.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "Glance", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display found for audio capture."])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await scStream.startCapture()
        stream = scStream

        // Mic via AVAudioEngine.
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.mixer.appendMic(buffer)
        }
        try engine.start()

        isRecording = true
        await MainActor.run { onStateChange?() }
    }

    /// Stop, write the transcript file, kick off summarization. Returns the
    /// file URL immediately; the summary is prepended when it lands.
    func stop() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? await stream?.stopCapture()
        stream = nil

        mixer.stop()
        channel?.stop()
        // Give in-flight final callbacks a beat to land.
        try? await Task.sleep(nanoseconds: 800_000_000)
        channel = nil

        await MainActor.run { onStateChange?() }
        return writeAndSummarize()
    }

    private func append(_ seg: Segment) {
        guard !seg.text.isEmpty else { return }
        segmentLock.lock()
        // Recognizer restarts can re-finalize the same utterance, exactly or
        // near-exactly (error-flush then final of the same audio). Drop the
        // shorter of overlapping consecutive lines.
        if let last = segments.last, Self.overlaps(last.text, seg.text) {
            if seg.text.count <= last.text.count {
                segmentLock.unlock()
                return
            }
            segments.removeLast()
            segments.append(seg)
            segmentLock.unlock()
            DispatchQueue.main.async { [weak self] in self?.onLiveReplaceLast?(seg) }
            return
        }
        segments.append(seg)
        segmentLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onLiveSegment?(seg) }
    }

    /// Near-duplicate heuristic: one line starts with most of the other
    /// (case-insensitive, first 40 chars of the shorter).
    static func overlaps(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        let probe = String(short.lowercased().prefix(40))
        guard probe.count >= 12 else { return long.lowercased().hasPrefix(short.lowercased()) }
        return long.lowercased().hasPrefix(probe)
    }

    // MARK: - SCStreamOutput (system audio → "Them")

    private var loggedFormat = false

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else {
            if !loggedFormat { meetingLog("system audio: PCM conversion FAILED") }
            loggedFormat = true
            return
        }
        if !loggedFormat {
            loggedFormat = true
            meetingLog("system audio format: \(pcm.format)")
        }
        mixer.appendSystem(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        meetingLog("SCStream stopped with error: \(error)")
        // Capture died (display change etc.) — stop cleanly rather than record half a call.
        Task { _ = await stop() }
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }

    // MARK: - Output

    private func writeAndSummarize() -> URL? {
        segmentLock.lock()
        let ordered = segments.sorted { $0.start < $1.start }
        segmentLock.unlock()

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm"
        let title = "Meeting \(df.string(from: startedAt))"

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Glance Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(title).md")

        let tf = DateFormatter()
        tf.dateFormat = "HH:mm:ss"
        var lines: [String] = ["# \(title)", ""]
        if ordered.isEmpty {
            lines.append("_No speech detected._")
        }
        for seg in ordered {
            let who = seg.speaker.isEmpty ? "" : " \(seg.speaker):"
            lines.append("**[\(tf.string(from: seg.start))]**\(who) \(seg.text)")
            lines.append("")
        }
        let transcript = lines.joined(separator: "\n")
        try? transcript.write(to: url, atomically: true, encoding: .utf8)

        if !ordered.isEmpty { summarize(transcript: transcript, into: url) }
        return url
    }

    /// One-shot `claude -p` → Granola-style notes prepended to the file. Fires
    /// `onSummarized` when the file is finalized, whether or not notes landed
    /// (so downstream action-item extraction always runs once).
    private func summarize(transcript: String, into url: URL) {
        guard case .ok(let binary, _) = ClaudeLocator.check() else {
            DispatchQueue.main.async { [weak self] in self?.onSummarized?(url) }
            return
        }

        let body = String(transcript.suffix(60_000)) // bound the prompt
        let prompt = """
        This is an automatic meeting transcript (speech-to-text, expect some \
        mis-heard words; speakers are not labeled). Write concise meeting \
        notes in Markdown with these sections: ## Summary (2-4 sentences), \
        ## Key Points (bullets), ## Decisions (bullets, or "None"), \
        ## Action Items (bullets, with owner when clear from context). \
        Output only the notes.

        \(body)
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["-p", prompt]
        proc.currentDirectoryURL = FileManager.default.temporaryDirectory
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        proc.terminationHandler = { [weak self] p in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            if p.terminationStatus == 0,
               let notes = String(data: data, encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !notes.isEmpty,
               let existing = try? String(contentsOf: url, encoding: .utf8) {
                let combined = notes + "\n\n---\n\n" + existing
                try? combined.write(to: url, atomically: true, encoding: .utf8)
            }
            DispatchQueue.main.async { self?.onSummarized?(url) }
        }
        do {
            try proc.run()
        } catch {
            DispatchQueue.main.async { [weak self] in self?.onSummarized?(url) }
        }
    }
}

/// One speech-recognition pipeline for one audio source. Restarts its request
/// periodically (and on recognizer errors, e.g. long silence) so on-device
/// recognition stays healthy across an hour-long call.
private final class ChannelRecognizer {

    let speaker: String
    var onSegment: ((MeetingTranscriber.Segment) -> Void)?
    var onPartial: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var segmentStart = Date()
    private var lastText = ""
    /// Longest hypothesis seen this request. Finals sometimes COLLAPSE to a
    /// fragment of what the partials showed (observed live: 45 s of speech
    /// finalized as "Calling Rose") — never commit less than the best partial
    /// unless the final is at least comparably informative.
    private var bestPartial = ""
    private var running = false
    private var restartTimer: Timer?
    private let stateQueue = DispatchQueue(label: "com.h57q3wq0c.glance.recognizer")

    /// Recognition works best on mono 16 kHz; system audio arrives as 48 kHz
    /// deinterleaved stereo. Convert everything to this.
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1, interleaved: false)!
    /// One converter per source format — mic and system buffers interleave
    /// with different formats; recreating a converter per buffer would thrash.
    private var converters: [AVAudioFormat: AVAudioConverter] = [:]

    /// On-device tasks fail instantly when the local model isn't installed
    /// ("No speech detected" within ~a second). After two of those, fall back
    /// to server-based recognition instead of looping forever.
    private var useOnDevice = true
    private var requestStartedAt = Date()
    private var instantFailures = 0

    init(speaker: String) {
        self.speaker = speaker
    }

    func start() {
        stateQueue.sync {
            running = true
            beginRequest()
        }
        // NO forced rolling restarts: audio arriving between endAudio() and
        // the next request went into a dead request and was lost (observed as
        // mid-paragraph gaps). Natural pause-finals segment the transcript;
        // the recognizer's ~1-minute request cap surfaces as an error, and the
        // error path salvages the best hypothesis before restarting.
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            if let converted = self.convert(buffer) {
                self.request?.append(converted)
            }
        }
    }

    /// stateQueue only. Convert any incoming format to mono 16 kHz.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == targetFormat { return buffer }
        let converter: AVAudioConverter
        if let cached = converters[buffer.format] {
            converter = cached
        } else if let made = AVAudioConverter(from: buffer.format, to: targetFormat) {
            converters[buffer.format] = made
            converter = made
        } else {
            return nil
        }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var served = false
        var convErr: NSError?
        converter.convert(to: out, error: &convErr) { _, status in
            if served {
                status.pointee = .noDataNow
                return nil
            }
            served = true
            status.pointee = .haveData
            return buffer
        }
        if convErr != nil { return nil }
        return out.frameLength > 0 ? out : nil
    }

    func stop() {
        restartTimer?.invalidate()
        restartTimer = nil
        stateQueue.sync {
            running = false
            request?.endAudio()
            // If the final callback never fires (silence), flush the partial.
            if !lastText.isEmpty {
                emit(lastText)
                lastText = ""
            }
        }
    }

    // stateQueue only ↓

    private func beginRequest() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = true
        if useOnDevice && recognizer?.supportsOnDeviceRecognition == true {
            req.requiresOnDeviceRecognition = true
        }
        segmentStart = Date()
        requestStartedAt = Date()
        lastText = ""
        bestPartial = ""
        request = req
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.stateQueue.async {
                if let result {
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        // Forced endAudio (rolling restart) can deliver an
                        // empty or COLLAPSED final. Commit the final only when
                        // it's at least ~60% the size of the best hypothesis;
                        // otherwise the best partial carries more real content.
                        let toEmit = text.count >= (self.bestPartial.count * 6) / 10
                            ? text : self.bestPartial
                        self.emit(toEmit)
                        self.lastText = ""
                        self.bestPartial = ""
                        self.onPartial?("")
                        if self.running { self.beginRequest() }
                    } else {
                        // Stamp the segment when speech first shows up, not at
                        // request start — concurrent late finals were sorting
                        // out of order in the saved notes.
                        if self.lastText.isEmpty && self.bestPartial.isEmpty {
                            self.segmentStart = Date()
                        }
                        self.lastText = text
                        if text.count > self.bestPartial.count { self.bestPartial = text }
                        self.onPartial?(text)
                    }
                } else if let error {
                    self.handleTaskError(error)
                }
            }
        }
    }

    /// stateQueue only. Flush partials, detect the broken-on-device case, and
    /// restart with a throttle so a failing recognizer can't spin-loop.
    private func handleTaskError(_ error: Error) {
        meetingLog("\(speaker) recognizer error: \(error.localizedDescription)")
        let salvage = bestPartial.count > lastText.count ? bestPartial : lastText
        if !salvage.isEmpty {
            emit(salvage)
        }
        lastText = ""
        bestPartial = ""
        onPartial?("") // never leave a stale/vanishing partial on screen
        guard running else { return }

        // Task died almost immediately → recognizer itself is broken for this
        // config (usually: on-device model not installed). Fall back to server.
        if Date().timeIntervalSince(requestStartedAt) < 1.5 {
            instantFailures += 1
            if instantFailures >= 2 && useOnDevice {
                useOnDevice = false
                instantFailures = 0
                meetingLog("\(speaker): on-device recognition keeps failing instantly — falling back to server-based recognition")
            }
        } else {
            instantFailures = 0
        }

        // Throttled restart (never a tight loop).
        stateQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.running else { return }
            self.beginRequest()
        }
    }

    private func emit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onSegment?(.init(start: segmentStart, speaker: speaker, text: t))
    }
}
