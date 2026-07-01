# Glance

A macOS menu-bar assistant that answers questions about whatever is on your
screen — without breaking flow. Press a global hotkey, a translucent overlay
appears, type a question, and the answer streams back inline. The LLM backend
is your **locally installed Claude Code CLI**, reusing its existing sign-in — no
API keys, no accounts, no subscription backend.

Implements `prd.md` (Screen-Aware Desktop Assistant). Personal tool.

## How it works

1. Hotkey (default **⌥Space**) → the active display is captured and a
   non-activating overlay appears, input focused.
2. Type a question, press ↩. The screenshot + question go to `claude` and the
   answer streams into the overlay as Markdown.
3. Ask follow-ups in the same overlay (context is kept). Press **Esc**, the
   hotkey again, or click away to dismiss — the session ends and the next
   invocation starts fresh.

Under the hood it runs one persistent

```
claude -p --input-format stream-json --output-format stream-json \
       --include-partial-messages --verbose
```

process per overlay session. The first question ships the screenshot inline as
a base64 image block, so Claude answers in a single turn with no permission
prompt. The process is spawned on invocation (not kept warm all day) to keep
the idle footprint negligible.

## Requirements

- macOS 14 (Sonoma) or later.
- Claude Code CLI installed and signed in (`claude` working in your terminal).
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

That's the whole surface (v1, by design).

## Privacy & cost — read this

This is a personal tool with deliberate, documented trade-offs (PRD NFR6):

- **Screenshots may contain sensitive content**, and because the backend is
  Claude Code, each query is a real Claude Code session. Claude Code persists
  its own transcript — **including the screenshot** — under
  `~/.claude/projects/…` on your own disk. Glance itself keeps the screenshot
  in memory only and drops it when the session ends, but it cannot control
  Claude Code's transcript. If that matters, prune those transcripts yourself.
- **Queries draw from your Claude Pro/Max usage quota.**
- Glance makes **no network calls of its own** — all traffic goes through the
  Claude CLI's own connection (NFR5).

## Not included (v1)

Audio/meeting capture, stealth/hidden-from-screen-share behavior, other LLM
providers, chat history across invocations, multi-user/accounts, Windows/Linux,
Mac App Store distribution. See the PRD "Out of Scope".

## Distribution

Direct download, Developer ID–signed and notarized (NFR7). The signing and
notarization steps are sketched at the bottom of `Scripts/build-app.sh`.
