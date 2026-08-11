# Glance

A macOS menu-bar assistant that answers questions about whatever is on your
screen — without breaking flow. Press a global hotkey, a translucent overlay
appears, type a question, and the answer streams back inline. Choose your
**locally installed and signed-in Claude Code CLI or Codex CLI** in Settings;
Glance reuses that CLI's existing sign-in — no API keys, no Glance account, or
Glance-hosted subscription backend.

Implements `prd.md` (Screen-Aware Desktop Assistant). Personal tool.

## How it works

1. Hotkey (default **⌥Space**) → the active display is captured and a
   non-activating overlay appears, input focused.
2. Type a question, press ↩. The screenshot + question go to the Ask backend
   selected in Settings (Claude Code or Codex), and the answer streams into the
   overlay as Markdown.
3. Ask follow-ups in the same overlay (context is kept). Press **Esc**, the
   hotkey again, or click away to dismiss — the session ends and the next
   invocation starts fresh.

Claude Code runs one persistent

```
claude -p --input-format stream-json --output-format stream-json \
       --include-partial-messages --verbose
```

process per overlay session. Codex runs a local `codex exec` process per turn
and resumes the CLI session for follow-ups. The first question includes the
screenshot, so either provider can answer in a single turn with no permission
prompt. Processes are started only when an overlay is invoked to keep the idle
footprint negligible.

## Requirements

- macOS 14 (Sonoma) or later.
- Claude Code CLI or Codex CLI installed and signed in (`claude` or `codex`
  working in your terminal). Select the installed provider in Settings.
- **Screen Recording** permission (System Settings → Privacy & Security →
  Screen Recording). Glance guides you there on first use.

## Build & run

```sh
Scripts/build-app.sh          # builds build/Glance.app (ad-hoc signed)
open build/Glance.app
```

Grant Screen Recording when prompted, then relaunch. The icon lives in the menu
bar (Settings, Quit). During development you can also `swift run`, but the
`.app` bundle is what gets the stable code identity Screen Recording remembers.

## Settings

- Rebind the global hotkey.
- Launch at login.
- Choose the **Ask backend**: Claude Code or Codex. The status row, Rescan, and
  Test actions apply to the selected local CLI.

That's the whole surface (v1, by design).

## Privacy & cost — read this

This is a personal tool with deliberate, documented trade-offs (PRD NFR6):

- **Screenshots may contain sensitive content.** Each query is a real local
  Claude Code or Codex session, and either provider may retain its own local
  transcript or session data, including screenshots. Claude attachments remain
  in Glance memory while they are submitted. For Codex attachments, Glance
  creates a per-backend private temporary directory with mode `0700` and a PNG
  with mode `0600`; the PNG is deleted when the Codex turn reaches terminal
  success/error, the process exits or times out, or the session/app shuts down.
  Glance cannot control provider-owned local storage, so review and prune that
  CLI's local data if needed.
- **Queries use the selected provider account** and may count against its plan
  usage or provider-managed billing, depending on how that CLI is signed in.
- Glance makes **no network calls of its own** — traffic, if any, goes through
  the selected CLI's own connection (NFR5).

## Not included (v1)

Audio/meeting capture, stealth/hidden-from-screen-share behavior, other LLM
providers, chat history across invocations, multi-user/accounts, Windows/Linux,
Mac App Store distribution. See the PRD "Out of Scope".

## Distribution

Direct download, Developer ID–signed and notarized (NFR7). The signing and
notarization steps are sketched at the bottom of `Scripts/build-app.sh`.
