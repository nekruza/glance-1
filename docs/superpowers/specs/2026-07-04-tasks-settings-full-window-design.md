# Tasks & Settings as Full App Windows

**Date:** 2026-07-04
**Status:** Approved

## Goal

Convert the Task board (and its in-page Settings) from a borderless floating
overlay panel into a real, resizable macOS app window — like Slack — while the
Ask overlay keeps its lightweight glass-panel form.

## Decisions (user-approved)

1. **App presence:** While the Tasks window (or legacy Settings window) is
   open, Glance switches to `.regular` activation policy — dock icon +
   Cmd-Tab. When the last such window closes, revert to `.accessory`
   (menu-bar only).
2. **Settings home:** Settings remains a page inside the Tasks window
   (existing `session.showSettings` / `TaskSettingsView`), now full-size.
3. **Visual style:** Solid dark, native title bar with standard traffic
   lights. No translucent glass, no rounded-rect chrome.
4. **Hotkey:** Task hotkey toggles the window — visible & key → hide;
   otherwise present (deminiaturize if needed).

## Design

### 1. Window (TaskOverlayController)

Replace the `OverlayPanel` in `Sources/Glance/Tasks/TaskOverlayController.swift`
with a standard `NSWindow`:

- `styleMask: [.titled, .closable, .miniaturizable, .resizable]`
- `title = "Glance Tasks"`
- `contentMinSize` 760×560; default first-open size 1000×700
- `setFrameAutosaveName("GlanceTasksWindow")` — remembers size/position
- `appearance = NSAppearance(named: .darkAqua)`; opaque background using the
  Theme's dark base color
- `isReleasedWhenClosed = false`; controller is the window delegate
- Remove mouse-position anchoring logic (`position()`, `reanchor`); the frame
  autosave + `center()` on first open handles placement.

### 2. TaskBoardView

`Sources/Glance/Tasks/TaskBoardView.swift` root:

- Replace fixed `.frame(width: 700, height: 640)` with
  `.frame(minWidth: 760, minHeight: 560)` and let it fill the window.
- Remove the rounded-rect glass background, `strokeBorder`, and `clipShape`;
  use a solid dark background color (full-bleed).
- The overlay-opacity preference no longer applies here (Ask overlay only).

### 3. Activation policy management

Small helper (in `TaskOverlayController` or a shared spot):

- On presenting the Tasks window (and on showing the legacy Settings window):
  `NSApp.setActivationPolicy(.regular)` then
  `NSApp.activate(ignoringOtherApps: true)`.
- On `windowWillClose` / explicit hide: if no other policy-holding Glance
  window remains visible, `NSApp.setActivationPolicy(.accessory)`.
- The Ask overlay never touches activation policy.

### 4. Settings routing

- Gear inside the board keeps setting `session.showSettings = true` (in-page).
- Status-menu "Settings…" routes through the coordinator to: present Tasks
  window with `session.showSettings = true`.
- Legacy small `NSWindow` in `StatusItemController` stays ONLY as the
  fallback when the task system is unavailable (Claude CLI missing) — the
  coordinator's existing fallback path (`onOpenSettings`).
- Ask-overlay gear already routes to the board settings page; unchanged
  besides the window presentation.

### 5. Hotkey toggle

`toggle()` in `TaskOverlayController`:

- Window visible and key → hide (`orderOut`), restore `.accessory` if
  appropriate.
- Miniaturized → `deminiaturize` + activate.
- Otherwise → present.

### 6. Out of scope

- Ask overlay: untouched (glass NSPanel, popUpMenu level, non-activating).
- No changes to TaskBoardSession logic, TaskStore, TaskRunner.
- No SwiftUI Scene/WindowGroup restructure.

## Error handling

- CLI missing → task system absent → Settings falls back to legacy window
  (existing behavior).
- Notification click-through (`reveal(taskId:)`) presents the window the same
  as the hotkey.

## Testing

- Build via existing Scripts build path; launch app.
- Verify: hotkey opens real window (title bar, resize, minimize); dock icon
  appears while open, disappears after close; frame persists across
  open/close; Settings gear shows full-size settings page; menu Settings…
  lands on the settings page; Ask overlay unchanged.
