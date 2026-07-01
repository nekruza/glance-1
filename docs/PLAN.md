# Glance — Implementation Plan

Screen-aware desktop assistant. macOS menu-bar app. Implements `prd.md`
(Screen-Aware Desktop Assistant). Working name: **Glance**.

## Requirement → component map

| Component | Requirements |
|---|---|
| `StatusItemController` | FR5 (menu bar, Settings/Quit, no Dock) |
| `HotkeyManager` (Carbon) | FR1 global hotkey incl. full-screen; FR17 rebind |
| `ScreenCaptureService` (ScreenCaptureKit) | FR6 capture cursor display; FR7 TCC prompt; FR8 no overlay in shot; FR9 temp lifetime |
| `OverlayPanel` / `OverlayController` (NSPanel non-activating) | FR2 latency; FR3 translucent always-on-top; FR4 dismissal |
| `OverlayView` (SwiftUI) | FR3 input+answer; FR11 streamed Markdown; FR13 working/error state |
| `MarkdownText` | FR11 subset markdown |
| `ClaudeBackend` + `ClaudeLocator` | FR10 send Q+shot; FR12 follow-ups; FR14 CLI backend; FR15 latency/warm; FR16 diagnostics |
| `Preferences` / `LaunchAtLogin` / `SettingsView` | FR17 rebind; FR18 launch-at-login; FR19 nothing else |
| `README.md` | NFR6 privacy disclosure |

## Backend mechanism (from addendum + verified against claude 2.1.197)

Persistent process per overlay session:

```
claude -p --input-format stream-json --output-format stream-json \
       --include-partial-messages --verbose
```

- Run in a neutral temp cwd (avoid picking up a project's CLAUDE.md / hooks).
- First user message = one NDJSON line: text question + inline base64 PNG
  `image` content block. Single agent turn, no Read-tool permission prompt.
- Parse stdout NDJSON: `stream_event → content_block_delta → text_delta.text`
  streams tokens; `result` ends the turn; `session_id` captured from events.
- Follow-up (FR12): write another user-message line to the same stdin; the
  live process keeps conversation context.
- Dismiss: terminate process; delete temp screenshot (FR9).
- Warm (FR15): pre-spawn the process on hotkey-down so start/auth overlaps
  with the user typing. Escape ramp noted in FR15 if bar unmet.

## Latency budget (FR2/FR15)

- Capture + panel show must be ≤150 ms → capture synchronously on hotkey,
  reuse a single pre-built panel (no per-invocation window alloc).
- First token ≤3 s warm → pre-spawned process + inline image (no extra turn).

## Non-goals (Out of Scope): audio, stealth, multi-provider, cross-invocation
history, multi-user, Windows/Linux, MAS.

## Build/run

SwiftPM executable target; `Scripts/build-app.sh` assembles a `.app` bundle
with `Info.plist` (`LSUIElement`), ad-hoc codesigns for local run. Release
path: Developer ID sign + notarize (NFR7) — documented, not automated in v1.
