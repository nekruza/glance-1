# Tasks & Settings Full App Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the Task board (with its in-page Settings) from a borderless floating overlay into a real, resizable macOS window with dock/Cmd-Tab presence while open.

**Architecture:** `TaskOverlayController` swaps its `OverlayPanel` for a standard `NSWindow`; a tiny `AppActivation` helper flips the app between `.accessory` and `.regular` based on which "app windows" are open; menu Settings… routes into the Tasks window's settings page, falling back to the legacy small window only when the task system is absent (CLI missing).

**Tech Stack:** Swift / AppKit / SwiftUI (NSHostingController), SwiftPM. No test framework in this repo — verification is `swift build` + scripted app launch.

**Spec:** `docs/superpowers/specs/2026-07-04-tasks-settings-full-window-design.md`

---

### Task 1: AppActivation helper

**Files:**
- Create: `Sources/Glance/AppActivation.swift`

- [ ] **Step 1: Create the helper**

```swift
import AppKit

/// Flips the app between menu-bar-only (.accessory) and full-app (.regular)
/// presence. Each "app window" (Tasks board, legacy Settings) acquires a
/// token while visible; when the last one releases, the dock icon goes away.
@MainActor
enum AppActivation {
    private static var holders = Set<String>()

    static func acquire(_ token: String) {
        holders.insert(token)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func release(_ token: String) {
        holders.remove(token)
        if holders.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: succeeds (file compiles, nothing uses it yet).

### Task 2: TaskOverlayController → real NSWindow

**Files:**
- Modify: `Sources/Glance/Tasks/TaskOverlayController.swift` (full rewrite below)

- [ ] **Step 1: Replace file contents**

```swift
import AppKit
import SwiftUI

/// Owns the task-board app window (full window, Slack-like — not an overlay).
/// Reusable window, frame autosaved, dock/Cmd-Tab presence while open via
/// AppActivation.
@MainActor
final class TaskOverlayController: NSObject, NSWindowDelegate {

    let session: TaskBoardSession
    private let store: TaskStore
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }
    var onOpenSettings: (() -> Void)?

    init(store: TaskStore, runner: TaskRunner, ai: TaskAI, ingest: ComposioIngest) {
        self.store = store
        session = TaskBoardSession(store: store, runner: runner, ai: ai, ingest: ingest)
        super.init()
        session.dismissHandler = { [weak self] in self?.dismiss() }
        session.settingsHandler = { [weak self] in
            self?.dismiss()
            self?.onOpenSettings?()
        }
    }

    func toggle() {
        if let window, window.isVisible, window.isKeyWindow {
            dismiss()
        } else {
            present()
        }
    }

    func present() {
        let window = ensureWindow()
        if window.isMiniaturized { window.deminiaturize(nil) }
        AppActivation.acquire("tasks")
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
        AppActivation.release("tasks")
    }

    /// Focus the board on a specific task (notification click-through, FR56).
    func reveal(taskId: UUID) {
        session.selectedTaskId = taskId
        present()
    }

    // MARK: - Window

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let host = NSHostingController(rootView: TaskBoardView(session: session, store: store))
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.title = "Glance Tasks"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.contentMinSize = NSSize(width: 760, height: 560)
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(red: 22/255, green: 24/255, blue: 29/255, alpha: 1)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 1000, height: 700))
        w.center()
        w.setFrameAutosaveName("GlanceTasksWindow")
        window = w
        return w
    }

    // Traffic-light close: window hides (isReleasedWhenClosed = false); drop
    // the app's dock presence with it.
    func windowWillClose(_ notification: Notification) {
        AppActivation.release("tasks")
    }
}
```

Notes:
- `OverlayPanel`, `position()`, `reanchor`, `onCancel` are gone — panel was
  the overlay mechanism; the ask overlay keeps its own `OverlayPanel`.
- `AppActivation.release` is idempotent (Set.remove), so explicit `dismiss()`
  plus `windowWillClose` double-release is harmless.
- Class now extends `NSObject` for `NSWindowDelegate`.
- Background color literal matches `Theme.glassTint` (22,24,29).

- [ ] **Step 2: Build**

Run: `swift build`
Expected: succeeds.

### Task 3: TaskBoardView full-bleed restyle

**Files:**
- Modify: `Sources/Glance/Tasks/TaskBoardView.swift:10` (remove prefs), `:31-41` (root modifiers), `:416-427` (remove closeButton)

- [ ] **Step 1: Remove the now-unused prefs property**

Delete line 10:
```swift
    @ObservedObject private var prefs = Preferences.shared
```
(Its only use was `prefs.overlayOpacity` in the glass background, removed next.)

- [ ] **Step 2: Replace root frame/background/chrome**

Replace lines 31–41:
```swift
        .frame(width: 700, height: 640)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.glassTint.opacity(prefs.overlayOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.glassBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(alignment: .topTrailing) { closeButton.padding(5) }
        .foregroundStyle(Theme.fg)
```
with:
```swift
        .frame(minWidth: 760, minHeight: 560, maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.glassTint)
        .foregroundStyle(Theme.fg)
```

- [ ] **Step 3: Delete the closeButton view**

Delete the whole `private var closeButton: some View { ... }` block
(lines ~416–427) — the window's traffic lights replace it. Also update the
file's doc comment (line 3) from "Task board overlay … Same dark-glass system"
to reflect the full-window form, e.g. "Task board app window (PRD V2 F1),
dark theme."

- [ ] **Step 4: Build**

Run: `swift build`
Expected: succeeds, no unused-variable warnings for `prefs`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Glance/AppActivation.swift Sources/Glance/Tasks/TaskOverlayController.swift Sources/Glance/Tasks/TaskBoardView.swift
git commit -m "Tasks board is a real resizable app window, not an overlay"
```

### Task 4: Settings… menu routes into the Tasks window

**Files:**
- Modify: `Sources/Glance/AppCoordinator.swift` (add `summonTaskSettings`, reuse in `showOverlay`)
- Modify: `Sources/Glance/MenuBar/StatusItemController.swift:12` area (new callback), `:121-139` (routing)
- Modify: `Sources/Glance/AppDelegate.swift:19-20` (wiring)

- [ ] **Step 1: Coordinator route**

In `AppCoordinator.swift`, below `summonTasks()` (line 68), add:

```swift
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
```

Then in `showOverlay()` (line 309), the ask-overlay gear handler becomes:

```swift
        overlay.session.settingsHandler = { [weak self] in
            guard let self else { return }
            self.overlay.dismiss()
            self.summonTaskSettings()
        }
```

- [ ] **Step 2: StatusItemController callback**

Next to `var onTasks: (() -> Void)?` (line 12) add:

```swift
    var onSettings: (() -> Void)?
```

Replace `openSettings` routing (lines 121–139):

```swift
    /// Legacy small Settings window — fallback used only when the task
    /// system (and its in-window settings page) is unavailable.
    func showSettings() { openLegacySettings() }

    @objc private func openSettings() {
        if let onSettings { onSettings() } else { openLegacySettings() }
    }

    private func openLegacySettings() {
        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Glance Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        settingsWindow = window
        AppActivation.acquire("settings-legacy")
        window.makeKeyAndOrderFront(nil)
    }
```

And extend `windowWillClose` (line 143):

```swift
    func windowWillClose(_ notification: Notification) {
        settingsWindow = nil
        AppActivation.release("settings-legacy")
    }
```

(The menu item at line 71 already targets `#selector(openSettings)` — no
change there. `NSApp.activate` inside the reuse path is covered by
`AppActivation.acquire` already having run when the window was created; the
extra explicit activate for reuse is fine to keep or replace with
`AppActivation.acquire("settings-legacy")` — use acquire for consistency.)

- [ ] **Step 3: AppDelegate wiring**

After line 19 (`statusItem.onTasks = ...`) add:

```swift
        statusItem.onSettings = { [weak coordinator] in coordinator?.summonTaskSettings() }
```

Keep line 20 (`coordinator.onOpenSettings = { statusItem?.showSettings() }`)
— it is now purely the legacy fallback.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/Glance/AppCoordinator.swift Sources/Glance/MenuBar/StatusItemController.swift Sources/Glance/AppDelegate.swift
git commit -m "Settings… menu opens the settings page in the Tasks window"
```

### Task 5: End-to-end verification

- [ ] **Step 1: Assemble and launch**

Run: `Scripts/build-app.sh && open build/Glance.app`
Expected: app launches to menu bar (no dock icon).

- [ ] **Step 2: Verify behaviors**

- Menu → Tasks…: real window — title bar, traffic lights, resizable,
  min ~760×560; dock icon + Cmd-Tab entry appear.
- Resize + move window, close via traffic light: dock icon disappears;
  reopen → size/position restored.
- Task hotkey: toggles window (front → hidden → front).
- Board footer gear: settings page fills the window; back arrow/close
  returns to board.
- Menu → Settings…: opens Tasks window directly on settings page.
- Ask overlay (main hotkey): unchanged glass panel, no dock icon.

- [ ] **Step 3: Fix anything found, rebuild, re-verify**
