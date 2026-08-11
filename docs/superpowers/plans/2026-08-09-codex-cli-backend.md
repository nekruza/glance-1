# Codex CLI Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a selectable local Codex CLI backend to Glance's screen-aware ask overlay without changing Claude-backed task features.

**Architecture:** A provider-neutral `AskBackend` protocol sits above the two CLIs. Claude retains its persistent stream process. Codex executes `codex exec --json` for each turn and resumes the returned session ID. A stored provider selection controls health checks, Settings, and overlay construction.

**Tech Stack:** Swift 5, SwiftUI/AppKit, Foundation `Process`, macOS 14, Codex CLI JSONL.

## Global Constraints

- Keep macOS 14 and add no package dependencies.
- Default to Claude Code for existing users; store no API key.
- Codex runs inside a Glance-private temporary directory with `--skip-git-repo-check`; never use sandbox or approval-bypass flags.
- Keep task board, transcription, Composio, and session-history browsing Claude-specific.
- Retain temporary PNG attachments while Codex consumes them, then delete them
  on terminal turn/process cleanup and during shutdown.

---

### Task 1: Introduce backend selection and the common ask interface

**Files:** Create `Sources/Glance/Backend/AskBackend.swift`; modify `Sources/Glance/Settings/Preferences.swift` and `Package.swift`; create `Tests/GlanceTests/AskBackendKindTests.swift`.

**Interfaces:** `AskBackendKind` has `.claude` and `.codex`; `AskBackendEvent` has `.token(String)`, `.completed`, and `.failed(String)`; `AskBackend` exposes `firstTokenTimeout`, `startWarm()`, `ask(question:imagePNG:onEvent:)`, and `shutdown()`.

- [ ] **Step 1: Write the failing test.**

```swift
XCTAssertEqual(AskBackendKind.defaultValue, .claude)
XCTAssertEqual(AskBackendKind(rawValue: "codex"), .codex)
```

- [ ] **Step 2: Run `swift test --filter AskBackendKindTests`.** Expected: FAIL because the enum and test target do not exist.

- [ ] **Step 3: Add the shared types, a SwiftPM test target, and `Preferences.askBackend`, persisted as `ask.backend` with a safe `.claude` fallback.**

```swift
protocol AskBackend: AnyObject {
  var firstTokenTimeout: TimeInterval { get set }
  func startWarm()
  func ask(question: String, imagePNG: Data?, onEvent: @escaping (AskBackendEvent) -> Void)
  func shutdown()
}
```

- [ ] **Step 4: Run `swift test --filter AskBackendKindTests`.** Expected: PASS.
- [ ] **Step 5: Commit.** Run `git add Package.swift Sources/Glance/Backend/AskBackend.swift Sources/Glance/Settings/Preferences.swift Tests/GlanceTests/AskBackendKindTests.swift && git commit -m "feat: add selectable ask backend preference"`.

### Task 2: Adapt Claude to the common interface without behavior changes

**Files:** Modify `Sources/Glance/Backend/ClaudeBackend.swift` and `Sources/Glance/Backend/StreamEvent.swift`; create `Tests/GlanceTests/ClaudeBackendTests.swift`.

**Interfaces:** `ClaudeBackend: AskBackend`; existing Claude CLI flags, stream decoder, history resume, and friendly errors remain unchanged.

- [ ] **Step 1: Write the failing mapping test.**

```swift
let line = try JSONDecoder().decode(StreamLine.self, from: fixture)
XCTAssertEqual(line.askBackendEvent, .token("hello"))
```

- [ ] **Step 2: Run `swift test --filter ClaudeBackendTests`.** Expected: FAIL because shared event mapping is absent.
- [ ] **Step 3: Replace `ClaudeBackend.Event` with `AskBackendEvent` and conform to `AskBackend`; do not alter command arguments or resume state.**
- [ ] **Step 4: Run `swift test --filter ClaudeBackendTests && swift test`.** Expected: PASS.
- [ ] **Step 5: Commit.** Run `git add Sources/Glance/Backend/ClaudeBackend.swift Sources/Glance/Backend/StreamEvent.swift Tests/GlanceTests/ClaudeBackendTests.swift && git commit -m "refactor: share ask backend events"`.

### Task 3: Add Codex discovery and provider-aware Settings tests

**Files:** Create `Sources/Glance/Backend/CodexLocator.swift`; modify `Sources/Glance/Backend/BackendTester.swift`; create `Tests/GlanceTests/CodexLocatorTests.swift`.

**Interfaces:** `CodexLocator.Status` mirrors Claude's locator; `BackendTester.test(kind:timeout:completion:)` selects the corresponding locator and command.

- [ ] **Step 1: Write the failing missing-binary test.**

```swift
XCTAssertEqual(BackendTester.message(for: .codex, status: .notFound),
               "Codex CLI not found. Install it and run `codex` to sign in.")
```

- [ ] **Step 2: Run `swift test --filter CodexLocatorTests`.** Expected: FAIL because `CodexLocator` is absent.
- [ ] **Step 3: Probe `~/.local/bin/codex`, `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, `/usr/bin/codex`, then login-shell `command -v codex`; validate with `--version`. Test with `codex exec --skip-git-repo-check "Reply with exactly: OK"`.**
- [ ] **Step 4: Run `swift test --filter CodexLocatorTests && codex --version`.** Expected: PASS and a version string.
- [ ] **Step 5: Commit.** Run `git add Sources/Glance/Backend/CodexLocator.swift Sources/Glance/Backend/BackendTester.swift Tests/GlanceTests/CodexLocatorTests.swift && git commit -m "feat: detect and test Codex CLI"`.

### Task 4: Implement Codex JSONL execution and session resumption

**Files:** Create `Sources/Glance/Backend/CodexBackend.swift` and `Sources/Glance/Backend/CodexStreamEvent.swift`; create `Tests/GlanceTests/CodexStreamEventTests.swift`.

**Interfaces:** `CodexBackend: AskBackend`; first turn runs `codex exec --json --skip-git-repo-check`; later turns run `codex exec resume <session-id> --json --skip-git-repo-check`.

- [ ] **Step 1: Write failing decoder tests.**

```swift
XCTAssertEqual(try CodexStreamEvent.decode(#"{"type":"thread.started","thread_id":"abc"}"#), .threadStarted("abc"))
XCTAssertEqual(try CodexStreamEvent.decode(#"{"type":"item.completed","item":{"type":"agent_message","text":"Hello"}}"#), .token("Hello"))
```

- [ ] **Step 2: Run `swift test --filter CodexStreamEventTests`.** Expected: FAIL because the decoder is absent.
- [ ] **Step 3: Build a serial buffered JSONL reader. Write image bytes into the private temp directory, pass the prompt through stdin using the unambiguous `- --image <path>` command form, and retain the file until terminal turn/process cleanup. Remove it on success, error, exit, timeout, shutdown, and deinitialization. Record the thread ID, forward answer text, emit completion, and terminate active work on timeout/dismissal.**
- [ ] **Step 4: Run `swift test --filter CodexStreamEventTests && codex exec --json --skip-git-repo-check "Reply with exactly: OK"`.** Expected: PASS and a completed message in JSONL.
- [ ] **Step 5: Commit.** Run `git add Sources/Glance/Backend/CodexBackend.swift Sources/Glance/Backend/CodexStreamEvent.swift Tests/GlanceTests/CodexStreamEventTests.swift && git commit -m "feat: add Codex CLI ask backend"`.

### Task 5: Wire the selection through coordinator and Settings

**Files:** Modify `Sources/Glance/AppCoordinator.swift`, `Sources/Glance/Settings/SettingsView.swift`, `Sources/Glance/Overlay/OverlaySession.swift`, and `Sources/Glance/Backend/PermissionOnboarding.swift`; extend `Tests/GlanceTests/AskBackendKindTests.swift`.

**Interfaces:** `AppCoordinator.backend` becomes `AskBackend?`; a factory constructs only the selected provider and returns its status label.

- [ ] **Step 1: Write the failing label test.**

```swift
XCTAssertEqual(AskBackendKind.codex.displayName, "Codex CLI")
```

- [ ] **Step 2: Run `swift test --filter AskBackendKindTests`.** Expected: FAIL because display metadata is absent.
- [ ] **Step 3: Replace `ClaudeBackend?` with `AskBackend?`; reset when selection changes. Keep history/resume visible only for Claude and keep `setupTasks()` on `ClaudeLocator`. Add an Ask backend picker; make status, Test, Rescan, and privacy copy selected-provider-specific.**
- [ ] **Step 4: Run `swift test && Scripts/build-app.sh`.** Expected: PASS and `build/Glance.app` exists.
- [ ] **Step 5: Commit.** Run `git add Sources/Glance/AppCoordinator.swift Sources/Glance/Settings/SettingsView.swift Sources/Glance/Overlay/OverlaySession.swift Sources/Glance/Backend/PermissionOnboarding.swift Tests/GlanceTests/AskBackendKindTests.swift && git commit -m "feat: select Codex or Claude for ask overlay"`.

### Task 6: Verify both providers and document the feature

**Files:** Modify `README.md` and `docs/superpowers/specs/2026-08-09-codex-cli-backend-design.md`.

- [ ] **Step 1: Document locally signed-in Claude Code or Codex, selected in Settings, and provider-owned session persistence.**
- [ ] **Step 2: Run `Scripts/build-app.sh && open build/Glance.app`.** Expected: Glance starts.
- [ ] **Step 3: For each provider, use Settings Test; send text and screenshot questions; send a follow-up; dismiss while generating. Return to Claude and confirm the task board still appears.**
- [ ] **Step 4: Run `swift test && git diff --check && git status --short`.** Expected: tests and diff check PASS.
- [ ] **Step 5: Commit.** Run `git add README.md docs/superpowers/specs/2026-08-09-codex-cli-backend-design.md && git commit -m "docs: describe Codex CLI ask backend"`.
