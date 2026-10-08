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
    private var taskInfrastructureConfigured = false

    /// The provider used by the current service bundle, read dynamically so a
    /// provider switch takes effect before the next request begins.
    var currentAutomationProvider: AutomationProvider? {
        providerServices?.provider
    }

    /// Opens the Settings window (wired to the status-item controller).
    var onOpenSettings: (() -> Void)?

    /// Open chats (the overlay's Chats menu). Each has its own transcript and
    /// CLI process, so one keeps working while the user is in another.
    private var chats: [OverlayChat]
    /// The chat on screen.
    private var activeChat: OverlayChat
    private var backendLifecycle: AskBackendLifecycle { activeChat.lifecycle }
    private var backend: AskBackend? { backendLifecycle.backend }
    /// Idle Claude processes kept running (~175 MB each). Past this, the
    /// least recently used idle chat closes its process and resumes the
    /// conversation by session id when reopened.
    static let maxLiveChats = 4
    private var suggestions: SuggestionService?
    private var pendingImagePNG: Data?
    private var pendingCaptureLabel: String = ""
    private var captureDisplay: () async throws -> CaptureResult = {
        try await ScreenCaptureService.captureActiveDisplay()
    }
    private var claudeStatus: ClaudeLocator.Status = .notFound
    /// Catalog facts from the Claude CLI for /status (see `wireCatalog`).
    private var claudeAccount: ClaudeAccount?
    private var mcpServers: [McpServerStatus]?
    private var defaultModel: String?

    /// Signed in? Asks the CLI's own status command; replaceable in tests.
    var authStatusCheck: (AskBackendKind, String) async -> Bool? = { kind, path in
        await AuthStatus.check(kind: kind, binaryPath: path)
    }
    private var setupRecheckInFlight = false
    private lazy var setupWatcher: ProviderSetupWatcher = {
        let watcher = ProviderSetupWatcher()
        watcher.onRecheck = { [weak self] in self?.recheckProviderSetup() }
        return watcher
    }()
    private var cancellables = Set<AnyCancellable>()

    init() {
        self.taskStore = TaskStore()
        self.overlay = OverlayController()
        let chat = OverlayChat(session: overlay.session)
        self.activeChat = chat
        self.chats = [chat]
        self.automationProviderFactory = AutomationProviderFactory()
        self.askBackendFactory = AskBackendFactory()
    }

    init(backendLifecycle: AskBackendLifecycle) {
        self.taskStore = TaskStore()
        self.overlay = OverlayController()
        let chat = OverlayChat(session: overlay.session, lifecycle: backendLifecycle)
        self.activeChat = chat
        self.chats = [chat]
        self.automationProviderFactory = AutomationProviderFactory()
        self.askBackendFactory = AskBackendFactory()
    }

    init(backendLifecycle: AskBackendLifecycle, overlay: OverlayController) {
        self.taskStore = TaskStore()
        self.overlay = overlay
        let chat = OverlayChat(session: overlay.session, lifecycle: backendLifecycle)
        self.activeChat = chat
        self.chats = [chat]
        self.automationProviderFactory = AutomationProviderFactory()
        self.askBackendFactory = AskBackendFactory()
    }

    /// Composition seam for the app's provider factory. It is intentionally
    /// the same lifecycle path used in production, rather than a test-only
    /// alternate task stack.
    init(backendLifecycle: AskBackendLifecycle, overlay: OverlayController,
         automationProviderFactory: AutomationProviderFactory,
         askBackendFactory: AskBackendFactory = AskBackendFactory(), taskStore: TaskStore,
         captureDisplay: @escaping () async throws -> CaptureResult = {
             try await ScreenCaptureService.captureActiveDisplay()
         }) {
        self.taskStore = taskStore
        self.overlay = overlay
        let chat = OverlayChat(session: overlay.session, lifecycle: backendLifecycle)
        self.activeChat = chat
        self.chats = [chat]
        self.automationProviderFactory = automationProviderFactory
        self.askBackendFactory = askBackendFactory
        self.captureDisplay = captureDisplay
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

        overlay.onDismiss = { [weak self] in self?.overlayDismissed() }

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
        // Every chat belongs to the old provider's CLI: keep only the one on
        // screen (reset by the caller) and stop its process.
        closeBackgroundChats()
        backendLifecycle.shutdown()
        suggestions?.cancel()
        taskRunner?.cancelAll(reason: "AI provider changed.")
        taskOverlay?.session.prepareForProviderReplacement()
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
        guard ensureBackend(for: activeChat), let backend,
              let lease = backendLifecycle.lease(for: backend) else { return }

        // Attachment defaults off, so don't block on Screen Recording — capture
        // opportunistically (FR8: before the overlay is shown) and open the
        // overlay either way. Permission is prompted only if the user attaches.
        Task { [weak self] in
            guard let self else { return }
            // Silent when Screen Recording isn't granted: capturing here would
            // raise the system TCC prompt on EVERY invocation. The prompt
            // belongs to the user-initiated attach path (FR7).
            let shot = await ScreenCaptureService.captureActiveDisplayIfPermitted()
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
    private func makeSelectedBackend(for chat: OverlayChat) -> Result<(backend: AskBackend, statusLabel: String), AutomationAvailability> {
        let kind = prefs.askBackend
        let selection: AskBackendFactory.Selection
        switch askBackendFactory.make(kind: kind, resuming: chat.resumePoint) {
        case .success(let selected):
            selection = selected
        case .failure(let status):
            return .failure(status)
        }

        let backend = selection.backend
        backend.configure(systemPrompt: TaskCapture.systemPrompt)
        // FR13. Resuming a large session (long transcript, project hooks) can
        // take far longer to first token than a fresh one.
        backend.firstTokenTimeout = chat.resumePoint == nil ? 30 : 120
        applyChosenModel(to: backend, kind: kind, chat: chat)
        wireCatalog(backend)
        backend.startWarm()
        return .success((backend, connectionLabel(for: kind, version: selection.version)))
    }

    /// Give a chat a running CLI — a fresh one, or one that resumes the chat's
    /// conversation when its process was closed. False when the CLI is
    /// missing or broken (the setup card is shown instead).
    @discardableResult
    private func ensureBackend(for chat: OverlayChat) -> Bool {
        guard chat.backend == nil else { return true }
        switch makeSelectedBackend(for: chat) {
        case .success(let made):
            chat.lifecycle.install(made.backend)
            // The process now carries the conversation (and reports its id).
            chat.resumePoint = nil
            if chat === activeChat { clearSetupIssue() }
            chat.session.backendConnected = true
            chat.session.backendLabel = made.statusLabel
            return true
        case .failure(let status):
            showSetupIssue(kind: prefs.askBackend, status: status)
            return false
        }
    }

    /// The selected CLI is missing or broken: open the overlay anyway with
    /// the fix-it steps, rather than a modal alert and no overlay.
    private func showSetupIssue(kind: AskBackendKind, status: AutomationAvailability) {
        guard let issue = ProviderSetupIssue.make(kind: kind, availability: status) else { return }
        presentSetupIssue(issue, label: "\(kind.displayName) not connected")
    }

    /// The CLI said it isn't signed in: put the question back in the box and
    /// offer Sign in, which runs the exact binary in use.
    private func handleSignedOut(kind: AskBackendKind, in chat: OverlayChat) {
        chat.session.returnLastQuestionToInput()
        switch askBackendFactory.availability(kind: kind) {
        case .available(let path, _):
            presentSetupIssue(.signedOut(kind: kind, binaryPath: path),
                              label: "\(kind.displayName) not signed in")
        case let status:
            showSetupIssue(kind: kind, status: status)
        }
    }

    private func presentSetupIssue(_ issue: ProviderSetupIssue, label: String) {
        let session = overlay.session
        session.setupIssue = issue
        session.backendConnected = false
        session.backendLabel = label
        session.setupRetryHandler = { [weak self] in self?.recheckProviderSetup() }
        session.setupTerminalHandler = { [weak self] command in
            self?.setupWatcher.runInTerminal(command)
        }
        session.settingsHandler = { [weak self] in
            self?.overlay.dismiss()
            self?.summonTaskSettings()
        }
        setupWatcher.start()
        if !overlay.isVisible { overlay.present() }
    }

    private func clearSetupIssue() {
        overlay.session.setupIssue = nil
        setupWatcher.stop()
    }

    /// Try again / the Terminal step finished / the user switched apps: see
    /// whether the fix landed. Only while the card is on screen, so a
    /// background check never pops the overlay up.
    private func recheckProviderSetup() {
        guard let issue = overlay.session.setupIssue, overlay.isVisible,
              !setupRecheckInFlight else { return }
        let kind = prefs.askBackend
        switch issue.problem {
        case .notInstalled, .broken:
            present() // re-locates the CLI; success clears the card
        case .signedOut:
            guard case .available(let path, _) = askBackendFactory.availability(kind: kind) else {
                present()
                return
            }
            setupRecheckInFlight = true
            Task { [weak self] in
                guard let self else { return }
                let signedIn = await self.authStatusCheck(kind, path)
                self.setupRecheckInFlight = false
                guard signedIn == true, self.overlay.session.setupIssue?.problem == .signedOut,
                      self.prefs.askBackend == kind else { return }
                // A process started before the sign-in may hold no
                // credentials: start a fresh one. The question stays typed.
                self.teardownBackend()
                self.clearSetupIssue()
                self.present()
            }
        }
    }

    private func showOverlay() {
        let kind = prefs.askBackend
        let generation = providerGeneration
        let showsHistory = kind == .claude
        let session = overlay.session
        session.showsHistory = showsHistory
        session.showsPermissionModes = kind == .claude
        session.backendKind = kind
        if !showsHistory { session.historySessions = [] }
        wireChatList()
        wire(activeChat)
        overlay.present()
        if showsHistory {
            // Populate the past-sessions list off the main thread (directory
            // scan + head parse of each candidate file). Sessions already open
            // as a chat are left out.
            Task { [weak self] in
                let sessions = await Task.detached(priority: .utility) {
                    SessionHistoryStore.recentSessions()
                }.value
                guard let self, self.prefs.askBackend == .claude,
                      self.isCurrentProvider(kind: kind, generation: generation) else { return }
                let open = Set(self.chats.compactMap(\.claudeSessionId))
                self.overlay.session.historySessions = sessions.filter { !open.contains($0.id) }
            }
        }
        session.captureLabel = pendingCaptureLabel
        // Reopened with the Sign in card still up: maybe they signed in meanwhile.
        if session.setupIssue?.problem == .signedOut { recheckProviderSetup() }
    }

    // MARK: - Chats

    private func wireChatList() {
        let list = overlay.chats
        list.newChatHandler = { [weak self] in self?.newChat() }
        list.selectHandler = { [weak self] id in self?.switchToChat(id) }
        list.closeHandler = { [weak self] id in self?.closeChat(id) }
        if activeChat.observers.isEmpty { observe(activeChat) }
        refreshChatList()
    }

    /// Point a chat's controls at that chat — its own backend, wherever the
    /// user is when its events arrive.
    private func wire(_ chat: OverlayChat) {
        let session = chat.session
        session.settingsHandler = { [weak self] in
            guard let self else { return }
            self.overlay.dismiss()
            self.summonTaskSettings()
        }
        session.historyHandler = session.showsHistory
            ? { [weak self] summary in self?.resumeHistorySession(summary) }
            : nil
        session.submitHandler = { [weak self, weak chat] question in
            guard let self, let chat else { return }
            self.handleSubmit(question, in: chat)
        }
        session.stopHandler = { [weak chat] in chat?.backend?.interrupt() }
        session.modelHandler = { [weak self, weak chat] value in
            guard let self, let chat else { return }
            self.selectModel(value, in: chat)
        }
        session.permissionModeHandler = { [weak chat] mode in
            chat?.backend?.setPermissionMode(mode)
        }
        session.permissionAnswerHandler = { [weak chat] request, allow in
            guard let chat else { return }
            chat.backend?.answerPermission(id: request.id, allow: allow)
            // An approved plan drops the CLI into Ask mode; carry on in Auto
            // instead, as the terminal does.
            if allow, request.isPlanApproval {
                chat.session.selectPermissionMode(.auto)
            }
        }
    }

    /// Keep the Chats menu in step with each chat's transcript and state.
    /// `@Published` fires before the change lands, hence the hop to main.
    private func observe(_ chat: OverlayChat) {
        let session = chat.session
        let turns = session.$turns
            .map { "\($0.count)|\($0.last?.failed == true)|\($0.first?.question ?? "")" }
            .removeDuplicates()
            .map { _ in () }
        let working = session.$isWorking.removeDuplicates().map { _ in () }
        let approval = session.$pendingPermission.map { $0 != nil }.removeDuplicates().map { _ in () }
        turns.merge(with: working, approval)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshChatList() }
            .store(in: &chat.observers)
    }

    private func refreshChatList() {
        let rows = chats
            .filter { !$0.isEmpty || $0 === activeChat }
            .sorted { $0.lastActive > $1.lastActive }
            .map { $0.row(isActive: $0 === activeChat) }
        if overlay.chats.rows != rows { overlay.chats.rows = rows }
    }

    private func makeChat() -> OverlayChat {
        let chat = OverlayChat()
        chat.session.adoptSharedState(from: activeChat.session)
        chats.append(chat)
        wire(chat)
        observe(chat)
        return chat
    }

    /// New chat (button, ⌘N, Chats menu): a fresh conversation with new
    /// context. The current one keeps running and stays in the menu.
    func newChat() {
        guard !activeChat.isEmpty else { return } // already a fresh chat
        let chat = makeChat()
        activate(chat)
        ensureBackend(for: chat)
    }

    func switchToChat(_ id: UUID) {
        guard let chat = chats.first(where: { $0.id == id }), chat !== activeChat else { return }
        activate(chat)
        ensureBackend(for: chat)
    }

    /// Close a chat for good (its CLI stops; a Claude session stays in Past
    /// sessions). Closing the one on screen shows the most recent other one.
    func closeChat(_ id: UUID) {
        guard let chat = chats.first(where: { $0.id == id }) else { return }
        if chat === activeChat {
            guard let next = chats.filter({ $0 !== chat && !$0.isEmpty })
                .max(by: { $0.lastActive < $1.lastActive }) else {
                clearSession() // the only chat: start it over
                return
            }
            activate(next)
            ensureBackend(for: next)
        }
        remove(chat)
    }

    private func activate(_ chat: OverlayChat) {
        let previous = activeChat
        guard chat !== previous else { return }
        previous.lastActive = Date()
        chat.lastActive = Date()
        chat.hasUnseenReply = false
        // Connection, command menu and model list may have updated while
        // this chat was in the background.
        chat.session.adoptSharedState(from: previous.session)
        activeChat = chat
        overlay.show(chat.session)
        // A chat left with nothing in it has nothing to come back to.
        if previous.isEmpty, !previous.session.isWorking { remove(previous) }
        parkIdleChats()
        refreshChatList()
    }

    private func remove(_ chat: OverlayChat) {
        guard chat !== activeChat, chats.contains(where: { $0 === chat }) else { return }
        chat.lifecycle.shutdown()
        chat.observers.removeAll()
        chats.removeAll { $0 === chat }
        refreshChatList()
    }

    /// Provider switch / full teardown: only the chat on screen survives.
    private func closeBackgroundChats() {
        for chat in chats where chat !== activeChat { remove(chat) }
    }

    /// Cap the idle CLI processes: close the least recently used idle chats'
    /// processes, keeping where to resume them.
    private func parkIdleChats() {
        var live = chats.filter { $0.backend != nil }.count
        guard live > Self.maxLiveChats else { return }
        let idle = chats
            .filter { $0 !== activeChat && $0.backend != nil
                && !$0.session.isWorking && $0.session.pendingPermission == nil }
            .sorted { $0.lastActive < $1.lastActive }
        for chat in idle where live > Self.maxLiveChats {
            guard let point = chat.backend?.resumePoint else { continue }
            chat.resumePoint = point
            chat.lifecycle.shutdown()
            live -= 1
        }
    }

    /// Clear button: drop the conversation (and any resumed session), start a
    /// fresh warm backend, and fall back to the idle prompt.
    private func clearSession() {
        teardownBackend()
        activeChat.session.clearTranscript()
        activeChat.resumePoint = nil
        activeChat.placeholderTitle = nil
        ensureBackend(for: activeChat)
        refreshChatList()
    }

    // MARK: - History resume

    /// Open a past Claude CLI session as a chat and show its transcript;
    /// follow-ups continue that conversation. The chat on screen stays open
    /// (unless it's empty, in which case the session takes its place).
    private func resumeHistorySession(_ summary: SessionSummary) {
        guard prefs.askBackend == .claude else { return }
        if let open = chats.first(where: { $0.claudeSessionId == summary.id }) {
            switchToChat(open.id)
            return
        }
        let currentProviderGeneration = providerGeneration
        let chat: OverlayChat
        if activeChat.isEmpty, !activeChat.session.isWorking {
            chat = activeChat
            chat.lifecycle.shutdown()
        } else {
            chat = makeChat()
        }
        chat.resumePoint = ResumePoint(sessionId: summary.id, cwd: summary.cwd)
        chat.placeholderTitle = summary.title
        activate(chat)
        guard ensureBackend(for: chat), let backend = chat.backend,
              let lease = chat.lifecycle.lease(for: backend) else { return }
        refreshChatList()

        let url = summary.fileURL
        let generation = chat.session.transcriptGeneration
        Task { [weak self, weak chat] in
            let turns = await Task.detached(priority: .userInitiated) {
                SessionHistoryStore.loadTurns(from: url)
            }.value
            guard let self, let chat, self.prefs.askBackend == .claude,
                  self.isCurrentProvider(kind: .claude, generation: currentProviderGeneration),
                  chat.lifecycle.isCurrent(lease) else { return }
            chat.session.loadTranscript(turns, ifGeneration: generation)
        }
    }

    // MARK: - Slash commands

    /// Start a new backend on the model picked in the footer (Claude only —
    /// Codex offers no model list).
    private func applyChosenModel(to backend: AskBackend, kind: AskBackendKind, chat: OverlayChat) {
        guard kind == .claude else { return }
        let session = chat.session
        if session.turns.isEmpty {
            // A new conversation starts in Auto (the backend's launch default)
            // on the last model picked.
            session.permissionMode = .defaultMode
            session.selectedModel = prefs.askModel ?? ModelOption.defaultValue
            if let model = prefs.askModel { backend.setModel(model) }
        } else {
            // A chat getting its process back keeps its own model and mode.
            if session.selectedModel != ModelOption.defaultValue { backend.setModel(session.selectedModel) }
            if session.permissionMode != .defaultMode { backend.setPermissionMode(session.permissionMode) }
        }
    }

    /// Footer model menu: remember the pick (for new chats) and switch this
    /// chat's live session.
    private func selectModel(_ value: String, in chat: OverlayChat) {
        guard prefs.askBackend == .claude else { return }
        prefs.askModel = value == ModelOption.defaultValue ? nil : value
        chat.backend?.setModel(value)
    }

    /// Feed a backend's command catalog (and account/MCP state) to the `/`
    /// menu and the /status report. The catalog outlives the backend, so the
    /// menu stays filled across /clear and resume while the new process starts.
    private func wireCatalog(_ backend: AskBackend) {
        backend.onCatalog { [weak self] catalog in
            guard let self else { return }
            if let commands = catalog.commands { self.overlay.session.cliCommands = commands }
            if let hidden = catalog.terminalOnly { self.overlay.session.terminalOnlyCommands = hidden }
            if let account = catalog.account { self.claudeAccount = account }
            if let servers = catalog.mcpServers { self.mcpServers = servers }
            if let model = catalog.defaultModel { self.defaultModel = model }
            if let models = catalog.models, !models.isEmpty { self.overlay.session.modelOptions = models }
        }
    }

    /// Answer the commands the headless CLI refuses (`LocalSlashCommand`)
    /// in place. True when `question` was one of them.
    private func handleLocalCommand(_ question: String, in chat: OverlayChat) -> Bool {
        guard let (command, _) = LocalSlashCommand.parse(question) else { return false }
        let session = chat.session
        let answer: String
        switch command {
        case .clear:
            clearSession()
            return true
        case .help:
            answer = SlashCommandReport.help(session.allSlashCommands)
        case .skills:
            answer = prefs.askBackend == .claude
                ? SlashCommandReport.skills(session.cliCommands)
                : "Skills come from Claude Code — switch the provider to Claude CLI in Settings to use them."
        case .status:
            answer = SlashCommandReport.status(.init(
                backendLabel: session.backendLabel,
                connected: session.backendConnected && chat.backend != nil,
                modelName: session.modelName,
                defaultModel: prefs.askBackend == .claude ? defaultModel : nil,
                account: prefs.askBackend == .claude ? claudeAccount : nil,
                mcpServers: prefs.askBackend == .claude ? mcpServers : [],
                commands: session.cliCommands))
        }
        session.replaceLastAnswer(answer)
        session.completeTurn()
        return true
    }

    // MARK: - Q&A

    private func handleSubmit(_ question: String, in chat: OverlayChat) {
        if handleLocalCommand(question, in: chat) { return }
        let kind = prefs.askBackend
        let session = chat.session
        // A chat whose idle process was closed gets it back here.
        if chat.backend == nil { ensureBackend(for: chat) }
        guard let backend = chat.backend else {
            session.failTurn("\(kind.displayName) unavailable.")
            return
        }
        let generation = providerGeneration
        let attach = session.attachImage

        // Text-only (the default) — send immediately.
        guard attach else {
            send(question, image: nil, via: backend, in: chat, kind: kind, generation: generation)
            return
        }

        // First question: use the still captured at invocation (already clean).
        if let firstShot = pendingImagePNG {
            pendingImagePNG = nil
            session.setLastTurnThumbnail(ScreenCaptureService.thumbnailImage(fromPNG: firstShot))
            send(question, image: firstShot, via: backend, in: chat, kind: kind, generation: generation)
            return
        }

        // An explicit attachment request can retry ScreenCaptureKit even when
        // the cached permission result is false (for example after granting
        // access in Settings). Speculative captures remain permission-gated.
        // Hide the overlay so it isn't in the fresh image (FR8).
        guard let lease = chat.lifecycle.lease(for: backend) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let png = try await self.captureExcludingOverlay()
                guard chat.lifecycle.isCurrent(lease),
                      self.isCurrentProvider(kind: kind, generation: generation) else { return }
                session.setLastTurnThumbnail(ScreenCaptureService.thumbnailImage(fromPNG: png))
                self.send(question, image: png, via: backend, in: chat, kind: kind, generation: generation)
            } catch {
                guard chat.lifecycle.isCurrent(lease),
                      self.isCurrentProvider(kind: kind, generation: generation) else { return }
                session.failTurn("Screenshot couldn't be attached. \(error.localizedDescription) Your question was not sent; try again or turn off the screenshot attachment.")
                session.input = question
            }
        }
    }

    /// Hide the overlay from capture, take a still, restore it.
    private func captureExcludingOverlay() async throws -> Data {
        overlay.setHiddenForCapture(true)
        defer { overlay.setHiddenForCapture(false) }
        // Let the compositor drop the now-transparent panel before capturing.
        try await Task.sleep(nanoseconds: 30_000_000) // 30 ms
        return try await captureDisplay().pngData
    }

    private func send(_ question: String, image: Data?, via backend: AskBackend, in chat: OverlayChat,
                      kind: AskBackendKind? = nil, generation: UInt? = nil) {
        let lifecycle = chat.lifecycle
        let session = chat.session
        guard let lease = lifecycle.lease(for: backend),
              lifecycle.isCurrent(lease) else { return }
        let kind = kind ?? prefs.askBackend
        let generation = generation ?? providerGeneration
        // Stopped while the screenshot was being taken: don't send it at all.
        guard let turnId = session.turns.last?.id,
              !session.lastTurnStopped else { return }
        // Events go to the chat that asked, on screen or not.
        backend.ask(question: question, imagePNG: image) { [weak self, weak chat] event in
            guard let self, let chat, lifecycle.isCurrent(lease),
                  self.isCurrentProvider(kind: kind, generation: generation),
                  // Events already queued when Stop was pressed.
                  session.turns.last?.id == turnId,
                  !session.lastTurnStopped else { return }
            switch event {
            case .token(let text): session.appendToken(text)
            case .completed:
                session.completeTurn()
                self.captureTasksFromAnswer(in: session)
                // Command output (/context, a skill's run…) isn't a Q&A to riff on.
                if !question.hasPrefix("/") { self.generateSuggestions(for: session) }
                self.noteBackgroundReply(in: chat)
            case .failed(let msg):
                session.failTurn(msg)
                self.noteBackgroundReply(in: chat)
            case .model(let id):    session.modelName = ModelCatalog.prettify(id)
            case .commandOutput(let text):
                session.appendCommandOutput(text)
                self.noteBackgroundReply(in: chat)
            case .signedOut: self.handleSignedOut(kind: kind, in: chat)
            case .activity(let label): session.setActivity(label)
            case .permissionRequest(let request): session.showPermissionRequest(request)
            case .permissionMode(let mode): session.permissionMode = mode
            }
        }
    }

    /// A chat in the background finished: flag it in the Chats menu.
    private func noteBackgroundReply(in chat: OverlayChat) {
        guard chat !== activeChat else { return }
        chat.hasUnseenReply = true
        refreshChatList()
    }

    /// V2 bridge: harvest `glance-task` blocks the assistant emitted when the
    /// user asked (possibly about a screenshot) to add tasks — create them on
    /// the board and show a confirmation in place of the raw block.
    private func captureTasksFromAnswer(in session: OverlaySession) {
        guard let last = session.turns.last, !last.failed else { return }
        let (cleaned, captured) = TaskCapture.extract(from: last.answer)
        guard !captured.isEmpty else { return }
        session.replaceLastAnswer(cleaned)
        for c in captured {
            let item = taskStore.add(TaskCapture.makeTaskItem(c))
            taskNotifications.post(message: "Task added: \(item.title)", taskId: item.id)
        }
    }

    /// Fill the suggestion chips from the just-finished turn (cheap one-shot
    /// provider call, separate from the conversation).
    private func generateSuggestions(for session: OverlaySession) {
        guard let suggestions, let kind = providerServices?.kind,
              let turn = session.turns.last, !turn.failed, !turn.answer.isEmpty
        else { return }
        let generation = providerGeneration
        let turnId = turn.id
        suggestions.suggest(question: turn.question, answer: turn.answer) { [weak self, weak session] list in
            guard let self, let session,
                  self.isCurrentProvider(kind: kind, generation: generation),
                  // Stale guard: still the same last turn, nothing in flight.
                  session.turns.last?.id == turnId,
                  !session.isWorking
            else { return }
            session.suggestions = list
        }
    }

    // MARK: - Teardown

    /// Overlay dismissed. Stop the selected CLI immediately and invalidate any
    /// capture/backend callbacks that were suspended or queued for this session.
    /// ⌥Space / Esc / ✕ only hides the overlay: the conversation and its CLI
    /// process stay, so the next summon shows the latest message and
    /// follow-ups keep their context. Trash or /clear starts fresh
    /// (`clearSession`); quitting or a provider switch ends it (`endSession`).
    func overlayDismissed() {
        // Each summon captures a fresh still; never send a stale one.
        pendingImagePNG = nil
        pendingCaptureLabel = ""
        overlay.session.captureLabel = ""
    }

    /// Full teardown: backend shut down, conversation wiped.
    func endSession() {
        setupWatcher.stop()
        closeBackgroundChats()
        teardownBackend()
        activeChat.resumePoint = nil
        activeChat.placeholderTitle = nil
        pendingImagePNG = nil
        pendingCaptureLabel = ""
        // A new invocation gets a new backend, so it must also start with an
        // empty visible conversation and no per-turn UI state.
        overlay.session.clearTranscript()
        overlay.session.captureLabel = ""
        refreshChatList()
    }

    /// App is quitting: don't leave orphaned claude processes behind, and
    /// flush the task store (FR48: active runs are cancelled — their state is
    /// already persisted as interrupted on next launch via failOrphanedRuns).
    func shutdown() {
        chats.forEach { $0.lifecycle.shutdown() }
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
