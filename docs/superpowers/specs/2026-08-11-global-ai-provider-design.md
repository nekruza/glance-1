# Global AI Provider Design

Date: 2026-08-11 · Status: approved by user

## Goal

Make the selected local AI CLI the single provider for every AI-driven part of
Glance. Selecting **Claude Code** makes all supported work use Claude Code;
selecting **Codex** makes the same work use Codex. No visible status, error,
model option, task run, or Composio request may silently invoke the other
provider.

The existing persisted `askBackend` preference remains the compatibility key,
but is presented in the UI as **AI provider**. Existing installs continue to
select Claude Code until the user changes it.

## In Scope

- Screen-aware Ask, image attachment, follow-up suggestions, and provider
  status/onboarding.
- Task capture, enrichment, prioritisation, task decomposition, helper drafts,
  agent-profile generation, and morning briefings.
- Plan generation and execution in the existing task runner, including JSONL
  progress, run transcripts, cancellation, and worktree isolation.
- Composio connected-app discovery, reads/pulls, and the existing explicit,
  user-approved outbound-write path.
- Meeting-transcript summarisation and downstream action-item extraction.
- Provider-specific model controls, error text, session metadata, and task
  settings copy.
- Safe provider changes: terminate and invalidate all active work owned by the
  old provider before constructing services for the new one.

## Non-goals

- Cloud APIs, API-key login, automatic provider fallback, or routing a single
  operation across both providers.
- Changing Glance's task approval gates, worktree policy, or Composio's
  read-only/default and explicit-approval/write policy.
- Importing Codex's external transcript store into the Claude-specific History
  menu. Current-session follow-ups continue to work for both providers; saved
  history is always provider-scoped and never displays a Claude session while
  Codex is selected.
- Guessing Codex model identifiers. Codex operations use the locally signed-in
  CLI's configured default unless future Codex-specific model discovery is
  deliberately added.

## Provider Boundary

Introduce a provider-neutral command layer, created from the selected
`AskBackendKind` at one central factory. It exposes four focused operations:

1. **One-shot text/JSON** — a bounded prompt returns final text for task AI,
   briefings, suggestions, and meeting notes.
2. **Streaming task run** — emits progress and final/session events, supports
   cancellation, and runs in the task's worktree or scratch workspace.
3. **Composio MCP call** — issues a provider-specific, per-call MCP command
   and returns final text to the current `ComposioIngest` parser.
4. **Availability and presentation metadata** — CLI path, version, provider
   display name, model-policy capabilities, and provider-specific diagnostics.

`TaskAI`, `TaskRunner`, `ComposioIngest`, `SuggestionService`, and
`MeetingTranscriber` depend on this boundary rather than a `binaryPath` for
Claude. They retain their existing task prompts, parsing, timeout behaviour,
and main-thread completion contracts. `AppCoordinator` uses the same factory
for both the ask overlay and task subsystem; it no longer calls
`ClaudeLocator` directly during task setup.

### Claude Code implementation

Claude retains the present `claude -p` command forms, Claude aliases
(`haiku`, `sonnet`, `opus`), MCP JSON configuration, streaming parser, and
tool allow/deny list. This is a refactor behind the shared boundary, not a
behaviour change.

### Codex implementation

One-shot work runs `codex exec --json --skip-git-repo-check -`, with the prompt
on standard input. The provider adapter parses Codex JSONL message events into
the same text/progress callbacks used by callers. Task execution additionally
uses its existing worktree or scratch directory as `--cd`, a workspace-write
sandbox, and no network access; the plan/review gates remain outside the CLI.

The task-run record gains provider-neutral metadata (`provider` and generic
CLI session ID). Legacy optional Claude session data remains decodable so
previous task history is preserved. App-owned JSONL transcripts and plan/review
history are provider-neutral and remain visible after a provider switch.

Codex has no safe equivalent of the app's Claude alias catalogue, so Codex UI
shows **Auto — Codex CLI default** and does not send stored Claude aliases to
Codex. Saved aliases are preserved and reappear when Claude Code is selected.

## Composio

Composio stays provider-owned per request. Claude continues to receive its
short-lived, mode-`0600` MCP JSON file. Codex receives transient configuration
overrides equivalent to:

```text
codex exec --json --skip-git-repo-check \
  -c mcp_servers.composio.url=... \
  -c mcp_servers.composio.bearer_token_env_var="GLANCE_COMPOSIO_TOKEN" -
```

Glance places the configured Composio key in that child process's environment
only; it does not call `codex mcp add` against the user's permanent Codex
configuration. Every pull and write error uses the selected provider's display
name (for example, `Codex exited 1`, never `Claude exited 1` while Codex is
selected). Prompts and the app-level outbound approval gate remain the
authority for Composio read/write intent.

## Provider Switching Lifecycle

Changing the provider is a session boundary:

1. Increment a provider-generation token before mutating UI state.
2. Dismiss the ask overlay; stop its backend and suggestion process.
3. Cancel task-run, plan, Composio, and meeting-summary work launched by the
   old provider. Persist existing partial task output as interrupted rather
   than allowing a hidden old process to continue.
4. Rebuild the task service bundle from the new provider only after old
   completions have been invalidated.
5. Clear provider-specific transient UI (suggestions, CLI status, model menu,
   overlay history) and refresh settings from the new provider.

Every async completion carries the generation/provider that launched it; it is
ignored if either no longer matches. This prevents a late Claude error or
response from updating a Codex screen (and vice versa).

## UI Behaviour

- Rename the Settings and task-settings picker to **AI provider**. Its status,
  test action, installation/sign-in alert, footer, privacy copy, and errors
  name exactly the selected CLI.
- The task board shows one provider status for its active service bundle. It
  either uses the selected, available CLI or reports that provider as missing;
  it does not silently fall back.
- Claude model controls retain the current alias/catalog display. Under Codex,
  task and agent model controls display one Auto/default choice and explain
  that the Codex CLI controls its model. Existing Claude-only aliases are not
  lost.
- The existing History control remains unavailable for Codex until a dedicated
  provider-safe Codex history browser exists. It never exposes Claude history
  or labels in a Codex session.

## Error Handling

- A missing or unsigned-in selected CLI prevents only AI work and gives the
  matching installation/sign-in instruction; local task-board data remains
  available.
- One-shot failures return the current graceful fallback (`nil`, no board
  corruption, retryable UI) with selected-provider wording.
- Streaming task failures retain partial local work/transcript, finish the run
  as failed/interrupted, release worktree locks, and drain queued work only
  when it belongs to the current provider generation.
- Provider changes, overlay dismissal, app termination, timeout, and process
  launch failure close pipes, terminate child processes, and remove temporary
  Composio/image artefacts.

## Verification

- Unit-test factory selection and ensure every task service receives the
  selected provider rather than a Claude path.
- Use fake CLIs to assert Claude and Codex argv/stdin/environment separately;
  Codex fixtures emit realistic JSONL events.
- Verify Codex Composio uses transient `mcp_servers.composio` configuration,
  passes its bearer token only in the child environment, and reports `Codex`
  in non-zero-exit errors.
- Verify provider changes cancel old ask/task/Composio/summary work and stale
  callbacks cannot update the new provider's UI.
- Verify Codex task execution has the expected working directory, sandbox,
  network restriction, parser, timeout, worktree, and approval-gate behaviour.
- Run the complete Swift test suite and `Scripts/build-app.sh`.
- Manually smoke-test each selected provider: overlay/image ask, suggestion,
  task triage, planning, a safe task run, Composio read, meeting summary, and
  a provider switch while work is active.

## Decision

Use a single global provider factory rather than replacing individual Claude
commands ad hoc. It makes the selected CLI an enforceable dependency across
the app, preserves Claude behaviour, and gives Codex its own command, event,
MCP, and model semantics without misleading cross-provider UI.
