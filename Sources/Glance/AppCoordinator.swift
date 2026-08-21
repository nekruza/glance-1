import AppKit
import ScreenCaptureKit
import Combine

/// Orchestrates the core flow (Core User Flow, FR1–FR16): hotkey → capture →
/// overlay → question → streamed answer → dismiss.
@MainActor
final class AppCoordinator {

    private let hotkey = HotkeyManager()
    private let overlay: OverlayController
    private let prefs = Preferences.shared

    // V2 task system. The store outlives a provider switch; only the
    // provider-owned services below are replaced.
    let taskStore: TaskStore
    private(set) var taskRunner: TaskRunner?
    private(set) var taskOverlay: TaskOverlayController?
    private var taskAI: TaskAI?
    let taskNotifications = TaskNotifications()

    private struct ProviderServices {
        let kind: AskBackendKind
        let generation: UInt
        let provider: AutomationProvider
        let taskAI: TaskAI
        let taskRunner: TaskRunner
        let ingest: ComposioIngest
    }

    private let automationProviderFactory: AutomationProviderFactory
    private let askBackendFactory: AskBackendFactory
    private var providerServices: ProviderServices?
    private var providerGeneration: UInt = 0
    /// Reader extraction has its own visible busy state. Providers are allowed
    /// to suppress callbacks when cancelled, so keep its completion at the
    /// lifecycle boundary and settle it explicitly on a provider change.
    private var pendingMeetingExtractionCompletions: [UUID: (Int) -> Void] = [:]
    private var taskInfrastructureConfigured = false

    /// The provider used by the current service bundle. Consumers such as the
    /// meeting transcriber read this dynamically so a provider switch takes
    /// effect before their next request begins.
    var currentAutomationProvider: AutomationProvider? {
        providerServices?.provider
    }

    /// A provider reference is not sufficient for work that may outlive a
    /// selection change: a future selection can build the same provider kind
    /// again. Capture this generation-bound lease and validate it immediately
    /// before applying any asynchronous result.
    func currentAutomationProviderLease() -> AutomationProviderLease? {
        guard let services = providerServices else { return nil }
        let kind = services.kind
        let generation = services.generation
        return AutomationProviderLease(provider: services.provider) { [weak self] in
            let check = { self?.isCurrentProvider(kind: kind, generation: generation) ?? false }
            if Thread.isMainThread { return check() }
            return DispatchQueue.main.sync(execute: check)
        }
    }

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

    private let backendLifecycle: AskBackendLifecycle
    private var backend: AskBackend? { backendLifecycle.backend }
    private var suggestions: SuggestionService?
    private var pendingImagePNG: Data?
    private var pendingCaptureLabel: String = ""
    private var claudeStatus: ClaudeLocator.Status = .notFound
    private var cancellables = Set<AnyCancellable>()

    init() {
        self.taskStore = TaskStore()
        self.overlay = OverlayController()
        self.backendLifecycle = AskBackendLifecycle()
        self.automationProviderFactory = AutomationProviderFactory()
        self.askBackendFactory = AskBackendFactory()
    }

    init(backendLifecycle: AskBackendLifecycle) {
        self.taskStore = TaskStore()
        self.overlay = OverlayController()
        self.backendLifecycle = backendLifecycle
        self.automationProviderFactory = AutomationProviderFactory()
        self.askBackendFactory = AskBackendFactory()
    }

    init(backendLifecycle: AskBackendLifecycle, overlay: OverlayController) {
        self.taskStore = TaskStore()
        self.overlay = overlay
        self.backendLifecycle = backendLifecycle
        self.automationProviderFactory = AutomationProviderFactory()
        self.askBackendFactory = AskBackendFactory()
    }

    /// Composition seam for the app's provider factory. It is intentionally
    /// the same lifecycle path used in production, rather than a test-only
    /// alternate task stack.
    init(backendLifecycle: AskBackendLifecycle, overlay: OverlayController,
         automationProviderFactory: AutomationProviderFactory,
         askBackendFactory: AskBackendFactory = AskBackendFactory(), taskStore: TaskStore) {
        self.taskStore = taskStore
        self.overlay = overlay
        self.backendLifecycle = backendLifecycle
        self.automationProviderFactory = automationProviderFactory
        self.askBackendFactory = askBackendFactory
    }

    func start() {
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
                self.replaceProviderServices(for: kind)
                self.overlay.session.resetForBackendChange(to: kind)
            }
            .store(in: &cancellables)

        // A hotkey grab lost at launch (combo held by an app that later quit)
        // is sticky — HotkeyManager retries on its own timer while any slot is
        // failed; wake is an extra nudge since sleep pauses timers.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.hotkey.retryFailedRegistrations() }
            .store(in: &cancellables)

        // NFR13: mark runs orphaned by a previous quit only once. Provider
        // switches retain these local records rather than recreating the store.
        taskStore.failOrphanedRuns()
        replaceProviderServices(for: prefs.askBackend)
        configureTaskInfrastructureIfNeeded()

        overlay.onDismiss = { [weak self] in self?.endSession() }

        // Warm ScreenCaptureKit's shareable-content cache so the first capture
        // isn't slow (helps FR2), and record whether capture actually works —
        // the TCC preflight lies for dev-signed builds (see hasPermission).
        Task { await ScreenCaptureService.probePermission() }
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

    /// A provider change is a hard async boundary. Increment the generation
    /// before any cancellation so every callback captured from the old bundle
    /// becomes stale immediately, even when a CLI finishes while it is being
    /// terminated.
    func replaceProviderServices(for kind: AskBackendKind) {
        providerGeneration &+= 1
        ModelCatalog.shared.providerDidChange()
        backendLifecycle.shutdown()
        suggestions?.cancel()
        taskRunner?.cancelAll(reason: "AI provider changed.")
        taskOverlay?.session.prepareForProviderReplacement()
        settlePendingMeetingExtractions()
        providerServices?.provider.cancelAll()
        setupTasks(for: kind, generation: providerGeneration)
    }

    private func setupTasks(for kind: AskBackendKind, generation: UInt) {
        let provider: AutomationProvider
        switch automationProviderFactory.make(kind: kind) {
        case .success(let selected):
            provider = selected
        case .failure(let status):
            // Keep the existing local task data and board available, but make
            // each new AI operation fail with the selected provider's exact
            // diagnostic rather than falling back to the previously selected CLI.
            provider = UnavailableAutomationProvider(
                kind: kind,
                message: AutomationProviderFactory.unavailableMessage(kind: kind, status: status)
            )
        }

        let ai = TaskAI(provider: provider)
        let runner = TaskRunner(store: taskStore, provider: provider)
        let ingest = ComposioIngest(provider: provider)
        let services = ProviderServices(kind: kind, generation: generation,
                                        provider: provider, taskAI: ai,
                                        taskRunner: runner, ingest: ingest)
        if let binaryPath = provider.descriptor.binaryPath {
            ModelCatalog.shared.refresh(for: kind, binaryPath: binaryPath,
                                        cliVersion: provider.descriptor.version)
        }
        providerServices = services
        taskAI = ai
        taskRunner = runner
        suggestions = SuggestionService(provider: provider)

        let overlayCtl: TaskOverlayController
        if let existing = taskOverlay {
            existing.replaceServices(runner: runner, ai: ai, ingest: ingest,
                                     generation: generation)
            overlayCtl = existing
        } else {
            overlayCtl = TaskOverlayController(store: taskStore, runner: runner,
                                               ai: ai, ingest: ingest,
                                               providerGeneration: generation)
            taskOverlay = overlayCtl
        }

        wireTaskCallbacks(services: services, overlay: overlayCtl)
    }

    private func isCurrentProvider(kind: AskBackendKind, generation: UInt) -> Bool {
        providerGeneration == generation
            && providerServices?.kind == kind
            && providerServices?.generation == generation
    }

    private func wireTaskCallbacks(services: ProviderServices, overlay: TaskOverlayController) {
        let kind = services.kind
        let generation = services.generation
        let runner = services.taskRunner

        overlay.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        runner.onEvent = { [weak self] message, taskId in
            guard let self, self.isCurrentProvider(kind: kind, generation: generation) else { return }
            self.taskNotifications.post(message: message, taskId: taskId)
        }
        runner.onGate = { [weak self] gate, message, taskId, runId in
            guard let self, self.isCurrentProvider(kind: kind, generation: generation) else { return }
            self.taskNotifications.postGate(gate, message: message, taskId: taskId, runId: runId)
        }
        runner.onTaskCompleted = { [weak self, weak overlay] in
            guard let self, self.isCurrentProvider(kind: kind, generation: generation) else { return }
            overlay?.session.boardCompositionChanged()
        }

        taskNotifications.onOpenTask = { [weak self, weak overlay] taskId in
            guard let self, self.isCurrentProvider(kind: kind, generation: generation) else { return }
            overlay?.reveal(taskId: taskId)
        }
        // One-click gate actions from a stale notification must never revive
        // a run owned by a provider that is no longer selected.
        taskNotifications.onApprovePlan = { [weak self, weak runner] runId in
            guard let self, self.isCurrentProvider(kind: kind, generation: generation) else { return }
            runner?.approvePlan(runId: runId)
        }
        taskNotifications.onRejectPlan = { [weak self, weak runner] runId, reason in
            guard let self, self.isCurrentProvider(kind: kind, generation: generation) else { return }
            runner?.rejectPlan(runId: runId, reason: reason)
        }
        taskNotifications.onApproveReview = { [weak self, weak runner] runId in
            guard let self, self.isCurrentProvider(kind: kind, generation: generation) else { return }
            runner?.approveReview(runId: runId, releaseBoundary: false)
        }
        taskNotifications.onRejectReview = { [weak self, weak runner] runId, reason in
            guard let self, self.isCurrentProvider(kind: kind, generation: generation) else { return }
            runner?.rejectReview(runId: runId, reason: reason)
        }

        overlay.session.openAskHandler = { [weak self] in
            guard let self, self.isCurrentProvider(kind: kind, generation: generation) else { return }
            self.summon()
        }
        overlay.session.pullNotifyHandler = { [weak self] message in
            guard let self, self.isCurrentProvider(kind: kind, generation: generation) else { return }
            self.taskNotifications.post(message: message,
                                        taskId: self.taskStore.inboxTasks().first?.id ?? UUID())
        }
        overlay.session.sendNotifyHandler = { [weak self] message, taskId in
            guard let self, self.isCurrentProvider(kind: kind, generation: generation) else { return }
            self.taskNotifications.post(message: message, taskId: taskId)
        }
        overlay.session.draftReadyNotifyHandler = { [weak self] message, taskId in
            guard let self, self.isCurrentProvider(kind: kind, generation: generation) else { return }
            let canSend = self.taskStore.task(taskId)?.outboundTarget != nil
            self.taskNotifications.postDraft(message: message, taskId: taskId, canSend: canSend)
        }
        taskNotifications.onApproveSendDraft = { [weak self, weak overlay] taskId in
            guard let self, self.isCurrentProvider(kind: kind, generation: generation),
                  let task = self.taskStore.task(taskId), task.status == .awaitingReview,
                  task.outboundTarget != nil else { return }
            overlay?.session.approveSend(task, editedDraft: nil)
        }
        overlay.session.briefingNotifyHandler = { [weak self] message in
            guard let self, self.isCurrentProvider(kind: kind, generation: generation) else { return }
            self.taskNotifications.postBriefing(message: message)
        }
        taskNotifications.onOpenBriefing = { [weak self, weak overlay] in
            guard let self, self.isCurrentProvider(kind: kind, generation: generation),
                  let overlay else { return }
            overlay.session.showSettings = false
            overlay.session.showAgents = false
            overlay.session.tab = .board
            overlay.session.showBriefing = true
            overlay.present()
        }

        TranscriptPanelModel.shared.summarizeHandler = { [weak self] entry in
            guard let self, self.isCurrentProvider(kind: kind, generation: generation) else { return }
            self.summarizeMeeting(entry)
        }
        TranscriptPanelModel.shared.extractTasksHandler = { [weak self] entry, done in
            guard let self, self.isCurrentProvider(kind: kind, generation: generation) else { return }
            self.extractMeetingTasks(entry, completion: done)
        }
    }

    private func configureTaskInfrastructureIfNeeded() {
        guard !taskInfrastructureConfigured else { return }
        taskInfrastructureConfigured = true
        taskNotifications.setup()
        hotkey.register(prefs.taskHotkey, for: .tasks) { [weak self] in
            self?.taskOverlay?.toggle()
        }
        prefs.$taskHotkey
            .dropFirst()
            .sink { [weak self] combo in
                self?.hotkey.register(combo, for: .tasks)
            }
            .store(in: &cancellables)
        startPullScheduler()
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
        let generation = providerGeneration
        let kind = providerServices?.kind
        // Meeting prep autopilot rides the same tick but has its own pref,
        // independent of scheduled pulls.
        if let session = taskOverlay?.session {
            autopilot.tick(session: session) { [weak self] message, taskId in
                guard let self, let kind,
                      self.isCurrentProvider(kind: kind, generation: generation) else { return }
                self.taskNotifications.post(message: message, taskId: taskId)
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
        guard let taskAI, let kind = providerServices?.kind,
              let text = try? String(contentsOf: notesURL, encoding: .utf8),
              text.count > 200 else { return } // skip empty/junk recordings
        let generation = providerGeneration
        let filename = notesURL.lastPathComponent
        let title = notesURL.deletingPathExtension().lastPathComponent
        taskAI.extractActionItems(meetingText: text) { [weak self] items in
            guard let self, self.isCurrentProvider(kind: kind, generation: generation),
                  let items, !items.isEmpty else { return }
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
        guard let taskAI, let kind = providerServices?.kind,
              let text = try? String(contentsOf: entry.url, encoding: .utf8) else {
            completion(0)
            return
        }
        let generation = providerGeneration
        let extractionID = UUID()
        pendingMeetingExtractionCompletions[extractionID] = completion
        taskAI.extractActionItems(meetingText: text) { [weak self] items in
            guard let self, self.isCurrentProvider(kind: kind, generation: generation) else {
                // The reader button owns this completion. A provider switch
                // must not apply the old result, but it still has to settle
                // the visible extracting state.
                self?.completeMeetingExtraction(extractionID, count: 0)
                return
            }
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
            self.completeMeetingExtraction(extractionID, count: items.count)
        }
    }

    private func settlePendingMeetingExtractions() {
        let completions = Array(pendingMeetingExtractionCompletions.values)
        pendingMeetingExtractionCompletions.removeAll()
        completions.forEach { $0(0) }
    }

    private func completeMeetingExtraction(_ id: UUID, count: Int) {
        guard let completion = pendingMeetingExtractionCompletions.removeValue(forKey: id) else { return }
        completion(count)
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
        let kind = prefs.askBackend
        let generation = providerGeneration
        // FR15 warm path: spawn the backend now so start/auth overlaps with the
        // user reading the overlay and typing.
        if backend == nil {
            guard let made = makeSelectedBackend() else { return }
            backendLifecycle.install(made.backend)
            overlay.session.backendConnected = true
            overlay.session.backendLabel = made.statusLabel
        }
        guard let backend,
              let lease = backendLifecycle.lease(for: backend) else { return }

        // Attachment defaults off, so don't block on Screen Recording — capture
        // opportunistically (FR8: before the overlay is shown) and open the
        // overlay either way. Permission is prompted only if the user attaches.
        Task { [weak self] in
            guard let self else { return }
            // Attempt regardless of the preflight — the capture itself is the
            // authoritative permission check and updates hasPermission, so a
            // grant given while the app is running is picked up here without
            // a relaunch.
            let shot = try? await ScreenCaptureService.captureActiveDisplay()
            guard self.backendLifecycle.isCurrent(lease),
                  self.isCurrentProvider(kind: kind, generation: generation) else { return }
            if let shot {
                self.pendingImagePNG = shot.pngData
                self.pendingCaptureLabel = shot.displayLabel
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
    /// describes that exact binary. Task automation is built separately from
    /// the same selected provider in `replaceProviderServices(for:)`.
    private func makeSelectedBackend() -> (backend: AskBackend, statusLabel: String)? {
        let kind = prefs.askBackend
        let selection: AskBackendFactory.Selection
        switch askBackendFactory.make(kind: kind) {
        case .success(let selected):
            selection = selected
        case .failure(let status):
            PermissionOnboarding.reportAskProvider(kind: kind, availability: status)
            return nil
        }

        let backend = selection.backend
        backend.configure(systemPrompt: TaskCapture.systemPrompt)
        backend.firstTokenTimeout = 30 // FR13
        backend.startWarm()
        return (backend, connectionLabel(for: kind, version: selection.version))
    }

    private func showOverlay() {
        let kind = prefs.askBackend
        let generation = providerGeneration
        let showsHistory = kind == .claude
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
                guard let self, self.prefs.askBackend == .claude,
                      self.isCurrentProvider(kind: kind, generation: generation) else { return }
                self.overlay.session.historySessions = sessions
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
        backendLifecycle.install(made.backend)
        overlay.session.backendConnected = true
        overlay.session.backendLabel = made.statusLabel
    }

    // MARK: - History resume

    /// Swap the backend for one that resumes the picked Claude CLI session and
    /// show its past transcript; follow-ups continue that conversation.
    private func resumeHistorySession(_ summary: SessionSummary) {
        guard prefs.askBackend == .claude else { return }
        let currentProviderGeneration = providerGeneration
        claudeStatus = ClaudeLocator.check()
        guard case .ok(let path, _) = claudeStatus else { return }
        teardownBackend()

        let backend = ClaudeBackend(binaryPath: path,
                                    resumeSessionId: summary.id,
                                    resumeCwd: summary.cwd)
        backend.configure(systemPrompt: TaskCapture.systemPrompt)
        // Resuming a large session (long transcript, project hooks) can take
        // far longer to first token than a fresh one.
        backend.firstTokenTimeout = 120
        backend.startWarm()
        backendLifecycle.install(backend)

        let url = summary.fileURL
        let generation = overlay.session.transcriptGeneration
        guard let lease = backendLifecycle.lease(for: backend) else { return }
        Task { [weak self] in
            let turns = await Task.detached(priority: .userInitiated) {
                SessionHistoryStore.loadTurns(from: url)
            }.value
            guard let self, self.prefs.askBackend == .claude,
                  self.isCurrentProvider(kind: .claude, generation: currentProviderGeneration),
                  self.backendLifecycle.isCurrent(lease) else { return }
            self.overlay.session.loadTranscript(turns, ifGeneration: generation)
        }
    }

    // MARK: - Q&A

    private func handleSubmit(_ question: String) {
        let kind = prefs.askBackend
        guard let backend else {
            overlay.session.failTurn("\(kind.displayName) unavailable.")
            return
        }
        let generation = providerGeneration
        let attach = overlay.session.attachImage

        // Text-only (the default) — send immediately.
        guard attach else {
            send(question, image: nil, via: backend, kind: kind, generation: generation)
            return
        }

        // Attach requested but no Screen Recording permission → prompt, send
        // text-only this turn.
        guard ScreenCaptureService.hasPermission else {
            PermissionOnboarding.promptForScreenRecording()
            send(question, image: nil, via: backend, kind: kind, generation: generation)
            return
        }

        // First question: use the still captured at invocation (already clean).
        if let firstShot = pendingImagePNG {
            pendingImagePNG = nil
            overlay.session.setLastTurnThumbnail(ScreenCaptureService.thumbnailImage(fromPNG: firstShot))
            send(question, image: firstShot, via: backend, kind: kind, generation: generation)
            return
        }

        // Follow-up: grab a FRESH shot of the current screen, hiding the overlay
        // so it isn't in the image (FR8).
        guard let lease = backendLifecycle.lease(for: backend) else { return }
        Task { [weak self] in
            guard let self else { return }
            let png = await self.captureExcludingOverlay()
            guard self.backendLifecycle.isCurrent(lease),
                  self.isCurrentProvider(kind: kind, generation: generation) else { return }
            if let png {
                self.overlay.session.setLastTurnThumbnail(ScreenCaptureService.thumbnailImage(fromPNG: png))
            }
            self.send(question, image: png, via: backend, kind: kind, generation: generation)
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

    private func send(_ question: String, image: Data?, via backend: AskBackend,
                      kind: AskBackendKind? = nil, generation: UInt? = nil) {
        guard let lease = backendLifecycle.lease(for: backend),
              backendLifecycle.isCurrent(lease) else { return }
        let kind = kind ?? prefs.askBackend
        let generation = generation ?? providerGeneration
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
            guard let self, self.backendLifecycle.isCurrent(lease),
                  self.isCurrentProvider(kind: kind, generation: generation) else { return }
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
    /// provider call, separate from the conversation).
    private func generateSuggestions() {
        guard let suggestions, let kind = providerServices?.kind,
              let turn = overlay.session.turns.last, !turn.failed, !turn.answer.isEmpty
        else { return }
        let generation = providerGeneration
        let turnId = turn.id
        suggestions.suggest(question: turn.question, answer: turn.answer) { [weak self] list in
            guard let self,
                  self.isCurrentProvider(kind: kind, generation: generation),
                  // Stale guard: still the same last turn, nothing in flight.
                  self.overlay.session.turns.last?.id == turnId,
                  !self.overlay.session.isWorking
            else { return }
            self.overlay.session.suggestions = list
        }
    }

    // MARK: - Teardown

    /// Overlay dismissed. Stop the selected CLI immediately and invalidate any
    /// capture/backend callbacks that were suspended or queued for this session.
    func endSession() {
        teardownBackend()
        pendingImagePNG = nil
        pendingCaptureLabel = ""
        // A new invocation gets a new backend, so it must also start with an
        // empty visible conversation and no per-turn UI state.
        overlay.session.clearTranscript()
        overlay.session.captureLabel = ""
    }

    /// App is quitting: don't leave orphaned claude processes behind, and
    /// flush the task store (FR48: active runs are cancelled — their state is
    /// already persisted as interrupted on next launch via failOrphanedRuns).
    func shutdown() {
        teardownBackend()
        taskRunner?.cancelAll()
        taskOverlay?.session.cancelProviderWork()
        providerServices?.provider.cancelAll()
        taskStore.flush()
    }

    private func teardownBackend() {
        backendLifecycle.shutdown()
        suggestions?.cancel()
    }
}

/// Keeps the task board usable when the selected CLI is unavailable. It never
/// launches the other provider; each attempted operation receives the selected
/// provider's diagnostic and local task data remains intact.
private final class UnavailableAutomationProvider: AutomationProvider {
    private final class FailureState {
        var cancelled = false
    }

    let descriptor: AutomationProviderDescriptor
    private let message: String

    init(kind: AskBackendKind, message: String) {
        descriptor = AutomationProviderDescriptor(kind: kind, version: "unavailable")
        self.message = message
    }

    func runText(_ request: AutomationRequest,
                 onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        fail(onEvent)
    }

    func startRun(_ request: AutomationRunRequest,
                  onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        fail(onEvent)
    }

    func runComposio(_ request: ComposioAutomationRequest, token: String,
                     onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        fail(onEvent)
    }

    func cancelAll() {}

    private func fail(_ onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        let state = FailureState()
        let cancellation = AutomationCancellation { state.cancelled = true }
        DispatchQueue.main.async {
            guard !state.cancelled else { return }
            onEvent(.failed(self.message))
        }
        return cancellation
    }
}
