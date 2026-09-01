---
name: verify
description: Build, launch, and AX-drive Glance.app to verify UI changes (no screen recording available)
---

# Verifying Glance changes

Build + launch (raw binary crashes — needs bundle):

```bash
./Scripts/build-app.sh && pkill -x Glance; sleep 1; open build/Glance.app
```

Screenshots return wallpaper only (Terminal lacks Screen Recording) — verify via the AX tree with `osascript`.

## Driving the UI

- Open task board: `key code 17 using option down` (⌥T) — but it TOGGLES. Always check `count of windows` of process "Glance" first; only press when 0. Two back-to-back osascript calls lose the window (it hides on focus loss) — do multi-step flows inside ONE script.
- Assign `entire contents of w` to a variable before iterating; inline use throws -1700 which `try` blocks swallow silently (symptom: empty output). Retry up to 6× / delay 1 when it returns few elements.
- SwiftUI buttons expose no title/description; identify by `help` (tooltip) text or position. Board footer: help "Settings", "Back to the board", "Open the ask overlay".
- Settings sidebar = 9 unlabeled AXButtons at x=10, y=136+31·i, in `Section` enum order (general, appearance, ai, agents, repos, connections, schedule, activity, about) → Connections is the 6th.
- Connections cards load via a `Codex -p` subprocess — poll for AXCheckBox count in a loop (5s × 24). Card switches are AXCheckBoxes; app names are AXStaticTexts at the same y.
- Board pull menu = AXPopUpButton with help containing "Fetch new work"; after AXPress, read `menu items of menu 1 of e` for titles.
- `round` is a reserved word in AppleScript loop variables.
- Behavior assertions: `defaults read com.h57q3wq0c.glance tasks.enabledSources` (and other `tasks.*` keys) after AX interactions — writes land immediately via Preferences didSet.
- AXPress bypasses hit testing; for overlay/hit-test regressions use System Events `click at {x,y}` instead.
