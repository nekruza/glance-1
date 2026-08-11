import AppKit
import ScreenCaptureKit
import Combine

/// Orchestrates the core flow (Core User Flow, FR1–FR16): hotkey → capture →
/// overlay → question → streamed answer → dismiss.
@MainActor
final class AppCoordinator {

    private let hotkey = HotkeyManager()
    private let overlay = OverlayController()
    private let prefs = Preferences.shared

    // V2 task system (created in start() once the CLI path is known).
    let taskStore = TaskStore()
    private(set) var taskRunner: TaskRunner?
    private(set) var taskOverlay: TaskOverlayController?
    private var taskAI: TaskAI?
    let taskNotifications = TaskNotifications()

    /// Opens the Settings window (wired to the status-item controller).
    var onOpenSettings: (() -> Void)?

    /// Toggles meeting transcription (wired to the app delegate's transcriber).
    var onToggleTranscription: (() -> Void)? {
        didSet { overlay.session.transcribeHandler = onToggleTranscription }
    }

    /// Reflect transcription state in the overlay's record button.
    func setTranscribing(_ recording: Bool) {
        overlay.session.isTranscribing = recording
    }

    private var backend: AskBackend?
    private var suggestions: SuggestionService?
    private var pendingImagePNG: Data?
    private var pendingCaptureLabel: String = ""
    private var claudeStatus: ClaudeLocator.Status = .notFound
    private var cancellables = Set<AnyCancellable>()

    func start() {
        claudeStatus = ClaudeLocator.check()

        hotkey.onFire = { [weak self] in self?.toggle() }
        hotkey.register(prefs.hotkey)

        // FR17: re-register whenever the user rebinds.
        prefs.$hotkey
            .dropFirst()
            .sink { [weak self] combo in self?.hotkey.register(combo) }
            .store(in: &cancellables)

        // A conversation belongs to one provider. Switching providers drops
        // the live process and transcript instead of mixing their context.
        prefs.$askBackend
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] kind in
                guard let self else { return }
                self.teardownBackend()
                self.overlay.session.clearTranscript()
                self.overlay.session.showsHistory = kind == .claude
                self.overlay.session.historySessions = []
                self.overlay.session.backendConnected = false
                self.overlay.session.backendLabel = "Checking \(kind.displayName)…"
            }
            .store(in: &cancellables)

        // A hotkey grab lost at launch (combo held by an app that later quit)
        // is sticky — HotkeyManager retries on its own timer while any slot is
        // failed; wake is an extra nudge since sleep pauses timers.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.hotkey.retryFailedRegistrations() }
            .store(in: &cancellables)

        setupTasks()

        overlay.onDismiss = { [weak self] in self?.endSession() }

        // Warm ScreenCaptureKit's shareable-content cache so the first capture
        // isn't slow (helps FR2). Best-effort.
        Task { _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
    }

    /// Menu-driven summon (same as the hotkey).
    func summon() {
        if !overlay.isVisible { present() }
    }

    /// Menu-driven task board summon (V2 FR20).
    func summonTasks() {
        taskOverlay?.present()
    }

    /// Settings lives as a page inside the Tasks window; fall back to the
    /// legacy Settings window when the task system is unavailable.
    func summonTaskSettings() {
        if let taskOverlay {
            taskOverlay.session.showSettings = true
            taskOverlay.present()
        } else {
            onOpenSettings?()
        }
    }

    // MARK: - V2 task system

    private func setupTasks() {
        // NFR13: mark runs orphaned by the previous quit.
        taskStore.failOrphanedRuns()

        // The task system needs the CLI; degrade silently if absent (the ask
        // overlay already surfaces CLI problems on use).
        guard case .ok(let path, let version) = ClaudeLocator.check() else { return }
        ModelCatalog.shared.refresh(binaryPath: path, cliVersion: version)
        let ai = TaskAI(binaryPath: path)
        taskAI = ai
        let runner = TaskRunner(store: taskStore, binaryPath: path)
        let ingest = ComposioIngest(binaryPath: path)
        let overlayCtl = TaskOverlayController(store: taskStore, runner: runner, ai: ai, ingest: ingest)
        overlayCtl.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        runner.onEvent = { [weak self] message, taskId in
            self?.taskNotifications.post(message: message, taskId: taskId)
        }
        runner.onGate = { [weak self] gate, message, taskId, runId in
            self?.taskNotifications.postGate(gate, message: message,
                                             taskId: taskId, runId: runId)
        }
        runner.onTaskCompleted = { [weak overlayCtl] in
            overlayCtl?.session.boardCompositionChanged()
        }
        taskNotifications.setup()
        taskNotifications.onOpenTask = { [weak overlayCtl] taskId in
            overlayCtl?.reveal(taskId: taskId)
        }
        // One-click gate actions from the notification itself. Approving a
        // review never releases boundary actions (push/PR) — those stay in-app.
        taskNotifications.onApprovePlan = { [weak runner] runId in
            runner?.approvePlan(runId: runId)
        }
        taskNotifications.onRejectPlan = { [weak runner] runId, reason in
            runner?.rejectPlan(runId: runId, reason: reason)
        }
        taskNotifications.onApproveReview = { [weak runner] runId in
            runner?.approveReview(runId: runId, releaseBoundary: false)
        }
        taskNotifications.onRejectReview = { [weak runner] runId, reason in
            runner?.rejectReview(runId: runId, reason: reason)
        }
        taskRunner = runner
        taskOverlay = overlayCtl

        hotkey.register(prefs.taskHotkey, for: .tasks) { [weak self] in
            self?.taskOverlay?.toggle()
        }
        prefs.$taskHotkey
            .dropFirst()
            .sink { [weak self] combo in
                self?.hotkey.register(combo, for: .tasks)
            }
            .store(in: &cancellables)

        overlayCtl.session.openAskHandler = { [weak self] in
            self?.summon()
        }

        // Scheduled pulls: notify even when the overlay is closed.
        overlayCtl.session.pullNotifyHandler = { [weak self] message in
            self?.taskNotifications.post(message: message,
                                         taskId: self?.taskStore.inboxTasks().first?.id ?? UUID())
        }
        // Approved outbound send succeeded — notify + deep-link to the task.
        overlayCtl.session.sendNotifyHandler = { [weak self] message, taskId in
            self?.taskNotifications.post(message: message, taskId: taskId)
        }
        // Autopilot draft parked in Review — the notification carries
        // "Approve & send" when the task has an outbound target, so routine
        // replies clear without opening the board.
        overlayCtl.session.draftReadyNotifyHandler = { [weak self] message, taskId in
            let canSend = self?.taskStore.task(taskId)?.outboundTarget != nil
            self?.taskNotifications.postDraft(message: message, taskId: taskId,
                                              canSend: canSend)
        }
        // The action is still one explicit user click per item — the same
        // trust boundary as the in-app button, minus the app-open cost.
        // Re-check the gate: the user may have edited/sent/rejected meanwhile.
        taskNotifications.onApproveSendDraft = { [weak self, weak overlayCtl] taskId in
            guard let task = self?.taskStore.task(taskId),
                  task.status == .awaitingReview,
                  task.outboundTarget != nil else { return }
            overlayCtl?.session.approveSend(task, editedDraft: nil)
        }
        // Morning briefing (A1): notify when it lands; click-through opens
        // the briefing panel on the board.
        overlayCtl.session.briefingNotifyHandler = { [weak self] message in
            self?.taskNotifications.postBriefing(message: message)
        }
        taskNotifications.onOpenBriefing = { [weak overlayCtl] in
            guard let overlayCtl else { return }
            overlayCtl.session.showSettings = false
            overlayCtl.session.showAgents = false
            overlayCtl.session.tab = .board
            overlayCtl.session.showBriefing = true
            overlayCtl.present()
        }
        startPullScheduler()

        // Transcript-pane reader actions.
        TranscriptPanelModel.shared.summarizeHandler = { [weak self] entry in
            self?.summarizeMeeting(entry)
        }
        TranscriptPanelModel.shared.extractTasksHandler = { [weak self] entry, done in
            self?.extractMeetingTasks(entry, completion: done)
        }
    }

    // MARK: - Scheduled pulls

    private var schedulerTimer: DispatchSourceTimer?
    private let autopilot = Autopilot()

    /// Minute tick; fires the configured pull when due. Overlap-safe: the
    /// session ignores pulls while one is running, and lastRun only advances
    /// when we actually trigger.
    private func startPullScheduler() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.schedulerTick() }
        timer.resume()
        schedulerTimer = timer
    }

    private func schedulerTick() {
        // Meeting prep autopilot rides the same tick but has its own pref,
        // independent of scheduled pulls.
        if let session = taskOverlay?.session {
            autopilot.tick(session: session) { [weak self] message, taskId in
                self?.taskNotifications.post(message: message, taskId: taskId)
            }
        }

        let prefs = Preferences.shared
        guard prefs.schedEnabled, !prefs.composioKey.isEmpty,
              let session = taskOverlay?.session, !session.isPulling else { return }

        let now = Date()
        let last = prefs.schedLastRun ?? .distantPast
        let due: Bool
        switch prefs.schedMode {
        case .hourly:  due = now.timeIntervalSince(last) >= 3600
        case .every4h: due = now.timeIntervalSince(last) >= 4 * 3600
        case .daily:
            let cal = Calendar.current
            let todayAt = cal.startOfDay(for: now)
                .addingTimeInterval(TimeInterval(prefs.schedDailyMinutes * 60))
            due = now >= todayAt && last < todayAt
        }
        guard due else { return }
        prefs.schedLastRun = now

        if let source = ComposioIngest.Source(rawValue: prefs.schedSource) {
            // A specific source that the user has since disabled is skipped.
            if prefs.isFetchEnabled(source) { session.pull(source) }
        } else {
            session.pullAll()
        }
    }

    // MARK: - Meeting reader actions

    /// Summarize saved meeting notes into the main overlay conversation: the
    /// visible turn is a short question; the notes ride along invisibly.
    private func summarizeMeeting(_ entry: MeetingHistory.Entry) {
        guard let backend,
              let text = try? String(contentsOf: entry.url, encoding: .utf8) else { return }
        overlay.session.turns.append(OverlaySession.Turn(question: "Summarize “\(entry.title)”"))
        overlay.session.isWorking = true
        overlay.session.suggestions = []
        let composed = """
        Saved meeting notes/transcript follow. Give a tight summary: 2-3 sentence \
        overview, key decisions, action items (with owners when identifiable).
        ---
        \(String(text.prefix(50_000)))
        """
        send(composed, image: nil, via: backend)
    }

    /// FR31 auto-ingest: after a transcription stops, extract the user's
    /// action items into the INBOX (ambient ingestion → accept gate, FR34) —
    /// unlike the reader's explicit "Add my tasks", which goes straight to
    /// ready.
    func autoIngestMeeting(notesURL: URL) {
        guard let taskAI,
              let text = try? String(contentsOf: notesURL, encoding: .utf8),
              text.count > 200 else { return } // skip empty/junk recordings
        let filename = notesURL.lastPathComponent
        let title = notesURL.deletingPathExtension().lastPathComponent
        taskAI.extractActionItems(meetingText: text) { [weak self] items in
            guard let self, let items, !items.isEmpty else { return }
            // Dedupe on sourceRef so re-processing the same transcript adds
            // nothing (I/O matrix: re-extraction skips existing keys).
            let existingKeys = Set(self.taskStore.tasks.compactMap { $0.sourceRef?.key })
            var created = 0
            for d in items {
                // Slugged title, not a positional index — re-extraction that
                // reorders or inserts items must still dedupe per item.
                let key = "\(filename)#\(Self.actionItemSlug(d.title))"
                guard !existingKeys.contains(key) else { continue }
                var t = TaskItem(title: d.title, source: .granola)
                t.status = .inbox
                t.descriptionMD = (d.description ?? "") + "\n\n_From: \(title)_"
                t.labels = d.labels ?? []
                t.taskKind = TaskKind(rawValue: d.taskKind ?? "") ?? .other
                t.estimate = TaskEstimate(rawValue: d.estimate ?? "")
                t.agentId = AgentProfile.idFor(name: d.agent)
                t.sourceRef = SourceRef(key: key, url: nil)
                t.aiFilledFields = ["description", "labels", "taskKind", "estimate", "agent"]
                _ = self.taskStore.add(t)
                created += 1
            }
            guard created > 0 else { return }
            self.taskNotifications.post(
                message: "\(created) action item\(created == 1 ? "" : "s") from the meeting — review in Inbox",
                taskId: self.taskStore.inboxTasks().first?.id ?? UUID())
        }
    }

    /// Stable per-item dedupe slug: lowercased alphanumerics with dashes,
    /// capped — the same action item re-extracted maps to the same key.
    private static func actionItemSlug(_ title: String) -> String {
        let slug = title.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { out, ch in
                if ch != "-" || out.last != "-" { out.append(ch) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(slug.prefix(60))
    }

    /// Extract the user's action items from saved notes → task board.
    private func extractMeetingTasks(_ entry: MeetingHistory.Entry,
                                     completion: @escaping (Int) -> Void) {
        guard let taskAI,
              let text = try? String(contentsOf: entry.url, encoding: .utf8) else {
            completion(0)
            return
        }
        taskAI.extractActionItems(meetingText: text) { [weak self] items in
            guard let self else { return }
            let items = items ?? []
            for d in items {
                var t = TaskItem(title: d.title, source: .granola)
                t.descriptionMD = (d.description ?? "") + "\n\n_From: \(entry.title)_"
                t.labels = d.labels ?? []
                t.taskKind = TaskKind(rawValue: d.taskKind ?? "") ?? .other
                t.estimate = TaskEstimate(rawValue: d.estimate ?? "")
                t.agentId = AgentProfile.idFor(name: d.agent)
                t.aiFilledFields = ["description", "labels", "taskKind", "estimate", "agent"]
                let added = self.taskStore.add(t)
                self.taskNotifications.post(message: "Task added: \(added.title)", taskId: added.id)
            }
            completion(items.count)
        }
    }

    /// Hotkey bindings that failed to register, for the menu warning line.
    func hotkeyWarnings() -> [String] {
        hotkey.failureDescriptions
    }

    /// Current backend status for the menu's status line.
    func backendStatusLine() -> (connected: Bool, label: String) {
        let kind = prefs.askBackend
        switch kind {
        case .claude:
            if case .ok(_, let version) = ClaudeLocator.check() {
                return (true, connectionLabel(for: kind, version: version))
            }
        case .codex:
            if case .ok(_, let version) = CodexLocator.check() {
                return (true, connectionLabel(for: kind, version: version))
            }
        }
        return (false, "\(kind.displayName) not connected")
    }

    // MARK: - Invocation

    private func toggle() {
        if overlay.isVisible {
            overlay.dismiss() // FR4: hotkey again dismisses
        } else {
            present()
        }
    }

    private func present() {
        // FR15 warm path: spawn the backend now so start/auth overlaps with the
        // user reading the overlay and typing. Reuse the live backend when
        // re-summoning — the conversation persists across dismissals.
        if backend == nil {
            guard let made = makeSelectedBackend() else { return }
            backend = made.backend
            overlay.session.backendConnected = true
            overlay.session.backendLabel = made.statusLabel
        }

        // Attachment defaults off, so don't block on Screen Recording — capture
        // opportunistically (FR8: before the overlay is shown) and open the
        // overlay either way. Permission is prompted only if the user attaches.
        Task { [weak self] in
            guard let self else { return }
            if ScreenCaptureService.hasPermission {
                if let shot = try? await ScreenCaptureService.captureActiveDisplay() {
                    self.pendingImagePNG = shot.pngData
                    self.pendingCaptureLabel = shot.displayLabel
                }
            }
            self.showOverlay()
        }
    }

    /// Provider version output → a compact footer label.
    private func shortVersion(_ raw: String, kind: AskBackendKind) -> String {
        let num = raw.split(separator: " ").first.map(String.init) ?? raw
        switch kind {
        case .claude:
            return "claude \(num)"
        case .codex:
            return raw.lowercased().hasPrefix("codex") ? raw : "codex \(num)"
        }
    }

    private func connectionLabel(for kind: AskBackendKind, version: String) -> String {
        "\(kind.displayName) connected · \(shortVersion(version, kind: kind))"
    }

    /// Construct only the selected ask provider and return the status text that
    /// describes that exact binary. Task automation intentionally bypasses this
    /// factory and remains wired to ClaudeLocator in setupTasks().
    private func makeSelectedBackend() -> (backend: AskBackend, statusLabel: String)? {
        let kind = prefs.askBackend
        let backend: AskBackend
        let version: String

        switch kind {
        case .claude:
            claudeStatus = ClaudeLocator.check()
            guard case .ok(let path, let detectedVersion) = claudeStatus else {
                PermissionOnboarding.reportClaudeStatus(claudeStatus)
                return nil
            }
            let claude = ClaudeBackend(binaryPath: path)
            claude.appendSystemPrompt = TaskCapture.systemPrompt
            backend = claude
            version = detectedVersion
        case .codex:
            let status = CodexLocator.check()
            guard case .ok(let path, let detectedVersion) = status else {
                PermissionOnboarding.reportCodexStatus(status)
                return nil
            }
            backend = CodexBackend(binaryPath: path)
            version = detectedVersion
        }

        backend.firstTokenTimeout = 30 // FR13
        backend.startWarm()
        return (backend, connectionLabel(for: kind, version: version))
    }

    private func showOverlay() {
        let showsHistory = prefs.askBackend == .claude
        overlay.session.showsHistory = showsHistory
        overlay.present()
        // Reflect CLI connection in the footer (present() only reaches here when
        // the CLI is OK, so show the connected version).
        overlay.session.settingsHandler = { [weak self] in
            guard let self else { return }
            self.overlay.dismiss()
            self.summonTaskSettings()
        }
        if showsHistory {
            overlay.session.historyHandler = { [weak self] summary in
                self?.resumeHistorySession(summary)
            }
        } else {
            overlay.session.historyHandler = nil
            overlay.session.historySessions = []
        }
        overlay.session.clearHandler = { [weak self] in
            self?.clearSession()
        }
        if showsHistory {
            // Populate the Claude History dropdown off the main thread
            // (directory scan + head parse of each candidate file).
            Task { [weak self] in
                let sessions = await Task.detached(priority: .utility) {
                    SessionHistoryStore.recentSessions()
                }.value
                guard self?.prefs.askBackend == .claude else { return }
                self?.overlay.session.historySessions = sessions
            }
        }
        overlay.session.captureLabel = pendingCaptureLabel
        overlay.onSubmit { [weak self] question in
            self?.handleSubmit(question)
        }
    }

    /// Clear button: drop the conversation (and any resumed session), start a
    /// fresh warm backend, and fall back to the idle prompt.
    private func clearSession() {
        teardownBackend()
        overlay.session.clearTranscript()
        guard let made = makeSelectedBackend() else { return }
        backend = made.backend
        overlay.session.backendConnected = true
        overlay.session.backendLabel = made.statusLabel
    }

    // MARK: - History resume

    /// Swap the backend for one that resumes the picked Claude CLI session and
    /// show its past transcript; follow-ups continue that conversation.
    private func resumeHistorySession(_ summary: SessionSummary) {
        guard prefs.askBackend == .claude else { return }
        claudeStatus = ClaudeLocator.check()
        guard case .ok(let path, _) = claudeStatus else { return }
        teardownBackend()

        let backend = ClaudeBackend(binaryPath: path,
                                    resumeSessionId: summary.id,
                                    resumeCwd: summary.cwd)
        // Resuming a large session (long transcript, project hooks) can take
        // far longer to first token than a fresh one.
        backend.firstTokenTimeout = 120
        backend.startWarm()
        self.backend = backend

        let url = summary.fileURL
        Task { [weak self] in
            let turns = await Task.detached(priority: .userInitiated) {
                SessionHistoryStore.loadTurns(from: url)
            }.value
            self?.overlay.session.loadTranscript(turns)
        }
    }

    // MARK: - Q&A

    private func handleSubmit(_ question: String) {
        guard let backend else {
            overlay.session.failTurn("Backend unavailable.")
            return
        }
        let attach = overlay.session.attachImage

        // Text-only (the default) — send immediately.
        guard attach else {
            send(question, image: nil, via: backend)
            return
        }

        // Attach requested but no Screen Recording permission → prompt, send
        // text-only this turn.
        guard ScreenCaptureService.hasPermission else {
            PermissionOnboarding.promptForScreenRecording()
            send(question, image: nil, via: backend)
            return
        }

        // First question: use the still captured at invocation (already clean).
        if let firstShot = pendingImagePNG {
            pendingImagePNG = nil
            overlay.session.setLastTurnThumbnail(ScreenCaptureService.thumbnailImage(fromPNG: firstShot))
            send(question, image: firstShot, via: backend)
            return
        }

        // Follow-up: grab a FRESH shot of the current screen, hiding the overlay
        // so it isn't in the image (FR8).
        Task { [weak self] in
            guard let self else { return }
            let png = await self.captureExcludingOverlay()
            if let png {
                self.overlay.session.setLastTurnThumbnail(ScreenCaptureService.thumbnailImage(fromPNG: png))
            }
            self.send(question, image: png, via: backend)
        }
    }

    /// Hide the overlay from capture, take a still, restore it.
    private func captureExcludingOverlay() async -> Data? {
        overlay.setHiddenForCapture(true)
        // Let the compositor drop the now-transparent panel before capturing.
        try? await Task.sleep(nanoseconds: 30_000_000) // 30 ms
        let png = try? await ScreenCaptureService.captureActiveDisplay().pngData
        overlay.setHiddenForCapture(false)
        return png
    }

    private func send(_ question: String, image: Data?, via backend: AskBackend) {
        // Real-time ask-about-the-call: while transcribing, the recent
        // transcript rides along invisibly (the overlay shows only the
        // question the user typed).
        var composed = question
        let excerpt = TranscriptPanelModel.shared.isRecording
            ? TranscriptPanelModel.shared.contextExcerpt() : ""
        if !excerpt.isEmpty {
            composed = """
            Live meeting transcript so far (automatic speech-to-text, may contain \
            mis-heard words; timestamps are HH:mm):
            ---
            \(excerpt)
            ---
            Answer the user's question. Use the transcript when the question \
            refers to the conversation/meeting; ignore it otherwise.

            Question: \(question)
            """
        }
        backend.ask(question: composed, imagePNG: image) { [weak self] event in
            guard let self else { return }
            switch event {
            case .token(let text): self.overlay.session.appendToken(text)
            case .completed:
                self.overlay.session.completeTurn()
                self.captureTasksFromAnswer()
                self.generateSuggestions()
            case .failed(let msg):  self.overlay.session.failTurn(msg)
            }
        }
    }

    /// V2 bridge: harvest `glance-task` blocks the assistant emitted when the
    /// user asked (possibly about a screenshot) to add tasks — create them on
    /// the board and show a confirmation in place of the raw block.
    private func captureTasksFromAnswer() {
        guard let last = overlay.session.turns.last, !last.failed else { return }
        let (cleaned, captured) = TaskCapture.extract(from: last.answer)
        guard !captured.isEmpty else { return }
        overlay.session.replaceLastAnswer(cleaned)
        for c in captured {
            let item = taskStore.add(TaskCapture.makeTaskItem(c))
            taskNotifications.post(message: "Task added: \(item.title)", taskId: item.id)
        }
    }

    /// Fill the suggestion chips from the just-finished turn (cheap one-shot
    /// haiku call, separate from the conversation).
    private func generateSuggestions() {
        guard prefs.askBackend == .claude,
              case .ok(let path, _) = claudeStatus,
              let turn = overlay.session.turns.last, !turn.failed, !turn.answer.isEmpty
        else { return }

        if suggestions == nil { suggestions = SuggestionService(binaryPath: path) }
        let turnId = turn.id
        suggestions?.suggest(question: turn.question, answer: turn.answer) { [weak self] list in
            guard let self,
                  // Stale guard: still the same last turn, nothing in flight.
                  self.overlay.session.turns.last?.id == turnId,
                  !self.overlay.session.isWorking
            else { return }
            self.overlay.session.suggestions = list
        }
    }

    // MARK: - Teardown

    /// Overlay dismissed. Keep the backend and transcript — the conversation
    /// survives until the user clears it (trash) — but drop the screenshot
    /// bytes (FR9); the next summon captures a fresh one.
    private func endSession() {
        pendingImagePNG = nil
        // Attaching is an explicit, per-summon opt-in — never carry it over.
        overlay.session.attachImage = false
    }

    /// App is quitting: don't leave orphaned claude processes behind, and
    /// flush the task store (FR48: active runs are cancelled — their state is
    /// already persisted as interrupted on next launch via failOrphanedRuns).
    func shutdown() {
        teardownBackend()
        taskRunner?.cancelAll()
        taskStore.flush()
    }

    private func teardownBackend() {
        backend?.shutdown()
        backend = nil
        suggestions?.cancel()
    }
}
