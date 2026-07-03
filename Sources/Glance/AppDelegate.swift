import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController()
    private let coordinator = AppCoordinator()
    private let transcriber = MeetingTranscriber()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // FR5 / FR3: menu-bar app, no Dock, no App Switcher entry.
        NSApp.setActivationPolicy(.accessory)

        // Accessory apps have no main menu by default, which silently kills
        // ⌘C/⌘V/⌘X/⌘A/⌘Z in every text field — key equivalents route through
        // the menu. Install a minimal one (never visible, only routing).
        installMainMenu()

        statusItem.onAsk = { [weak coordinator] in coordinator?.summon() }
        statusItem.onTasks = { [weak coordinator] in coordinator?.summonTasks() }
        coordinator.onOpenSettings = { [weak statusItem] in statusItem?.showSettings() }
        statusItem.statusProvider = { [weak coordinator] in
            coordinator?.backendStatusLine() ?? (false, "Claude CLI status unknown")
        }
        statusItem.onToggleTranscription = { [weak self] in self?.toggleTranscription() }
        statusItem.isTranscribing = { [weak self] in self?.transcriber.isRecording ?? false }

        // Live transcript pane (V2): transcriber → shared panel model.
        let panel = TranscriptPanelModel.shared
        transcriber.onLiveSegment = { seg in panel.append(text: seg.text, at: seg.start) }
        transcriber.onLiveReplaceLast = { seg in panel.replaceLast(text: seg.text, at: seg.start) }
        transcriber.onLivePartial = { text in panel.updatePartial(text) }
        panel.startHandler = { [weak self] in
            guard let self, !self.transcriber.isRecording else { return }
            self.toggleTranscription()
        }
        panel.stopHandler = { [weak self] in
            guard let self, self.transcriber.isRecording else { return }
            self.toggleTranscription()
        }
        coordinator.onToggleTranscription = { [weak self] in self?.toggleTranscription() }
        transcriber.onStateChange = { [weak self] in
            guard let self else { return }
            self.statusItem.refreshTranscribeState()
            self.coordinator.setTranscribing(self.transcriber.isRecording)
        }
        statusItem.install()
        coordinator.start()
    }

    private func toggleTranscription() {
        if transcriber.isRecording {
            Task { [weak self] in
                guard let self else { return }
                TranscriptPanelModel.shared.recordingStopped()
                if let url = await self.transcriber.stop() {
                    // Show the notes; the AI summary is prepended when ready.
                    NSWorkspace.shared.open(url)
                    // FR31: action items → Inbox for review.
                    self.coordinator.autoIngestMeeting(notesURL: url)
                }
            }
            return
        }
        MeetingTranscriber.requestPermissions { [weak self] ok, message in
            guard let self else { return }
            guard ok else {
                if let message { self.alert("Can't start transcription", message) }
                return
            }
            Task {
                do {
                    try await self.transcriber.start()
                    TranscriptPanelModel.shared.recordingStarted()
                } catch {
                    self.alert("Transcription failed to start", error.localizedDescription)
                }
            }
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Glance",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All",
                     action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Start Dictation…",
                     action: Selector(("startDictation:")), keyEquivalent: "")
        editItem.submenu = edit

        NSApp.mainMenu = main
    }

    // Menu-bar app: closing a window (e.g. Settings) must not quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // The backend now outlives overlay dismissals; kill it on quit so no
    // orphaned claude process lingers.
    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }
}
