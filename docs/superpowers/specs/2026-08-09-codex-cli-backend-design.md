# Codex CLI Backend Design

## Goal

Let the Glance ask overlay use either the locally authenticated Claude Code
CLI or Codex CLI. The user selects the backend in Settings; existing installs
continue to use Claude Code unless they explicitly switch.

## Scope

- Add a persisted `AskBackend` preference with `claude` and `codex` cases.
- Add a Settings picker, per-backend availability/version status, rescan, and
  a test action for the selected backend.
- Add `CodexLocator`, matching the Finder-safe binary resolution pattern used
  by `ClaudeLocator`.
- Add `CodexBackend` for the ask overlay. It invokes `codex exec --json`,
  passes a captured first-turn image with `--image`, reads JSONL events for
  incremental text, and stores the returned session ID.
- Send follow-ups through `codex exec resume <session-id> --json` so each
  overlay session preserves context.
- Keep Claude's current persistent stream-json implementation unchanged.
- Surface clear errors for missing CLI, unavailable sign-in, timeout, and
  unexpected process exit.

## Non-goals

- Replacing Claude Code or changing the task board, transcription, Composio,
  or agent-runner paths, which currently require Claude-specific behavior.
- Adding API-key storage, model selection, provider fallback, or cross-provider
  conversation history.
- Importing or displaying historical Codex sessions in the existing
  Claude-specific History UI.

## Architecture

Introduce a small `AskBackend` protocol used only by the screen-aware ask
overlay. It exposes the existing lifecycle: warm/start, ask, and shutdown,
and emits token/completed/failed events. `ClaudeBackend` conforms without
changing its command protocol; `CodexBackend` conforms by creating a process
per turn and resuming with the most recently received Codex session ID.

`AskBackendKind` is stored in `Preferences` and defaults to `.claude`.
`AppCoordinator` creates the matching backend for new and resumed overlay
sessions. It continues to initialize the task system exclusively from
`ClaudeLocator`, so changing the ask provider cannot alter task automation.

## Codex Turn Flow

1. On the first prompt, Glance writes the in-memory PNG to a private temporary
   file and launches `codex exec --json --skip-git-repo-check --image <file>`
   with the question as the prompt.
2. The temporary image file is removed once the child has received it, and is
   also removed during error/shutdown cleanup.
3. The backend consumes Codex JSONL events, forwarding assistant text deltas
   to the overlay and recording the thread/session ID.
4. Follow-ups run `codex exec resume <session-id> --json` with the next
   question. A fresh image, when supplied, is attached with `--image`.
5. Dismissal terminates an in-flight process and drops the retained session ID
   and image file references.

Codex is launched in Glance's private temporary working directory and with
`--skip-git-repo-check`. It does not receive broad filesystem or approval
bypass flags.

## UI and Errors

Settings presents an **Ask backend** picker with Claude Code and Codex. The
status row labels the selected CLI and its detected version; Test and Rescan
operate on that selection. The privacy note names the selected local CLI and
states that Claude Code or Codex may retain provider-owned local
transcript/session data, including screenshots.

If Codex is absent, Glance directs the user to install and sign in through the
local `codex` command. Authentication, quota, and timeout failures name Codex
explicitly. Claude's wording and behavior remain as-is.

## Testing and Verification

- Unit-test backend-kind preference defaults and persistence.
- Unit-test Codex JSONL parsing against representative thread-start, text
  delta, completed, and error events.
- Build the release app with `Scripts/build-app.sh`.
- Manually test both selected backends: first screenshot question, streamed
  response, follow-up, dismissal during generation, missing-binary status,
  and Settings Test.
- Confirm the documentation tells users to select a locally signed-in Claude
  Code or Codex CLI in Settings and explains that either CLI may keep its own
  local session data.

## Decision

Use a selectable backend rather than automatic fallback. It keeps the user's
chosen account, model, authentication, and usage expectations explicit while
preserving all existing Claude behavior.
