# Agents Section — Social Profile Redesign

Date: 2026-07-06 · Status: approved by user

## Goal

Agents section (Settings → Skill profiles) redesigned to feel like each agent is a person: human name, avatar, bio, activity feed of completed tasks, performance stats, star ratings. Stays inside `TaskSettingsView` (not promoted to top-level nav).

## 1. Data model

`AgentProfile.swift`:
- New field `var humanName: String?` — display name ("Alex"). `name` stays the role label ("Coder"). `humanName` nil → UI falls back to role only (custom/AI-generated agents are not forced to have one).
- `builtIns` gains a 5th entry, **Analyst** (opus model, SQL/analytics skills, tool allowlist matching other data-focused work) — closes the gap between shipped code (4 built-ins) and what's shown in the current UI screenshot.
- Proposed roster:

| role (`name`) | `humanName` | icon |
|---|---|---|
| Coder | Alex | 💻 |
| Writer | Mia | ✍️ |
| Researcher | Sam | 🔍 |
| Reviewer | Jordan | ✅ |
| Analyst | Priya | 📊 |

`TaskModels.swift` — `TaskRun` gains:
- `var agentId: UUID?` — stamped from `task.agentId` at run creation, so activity history survives later task edits/reassignment.
- `var rating: Int?` — 1-5 stars, nil = unrated.

## 2. UI — `TaskSettingsView.swift`

`agentRow(_:)` redesigned:
- Avatar circle (icon emoji, 36pt).
- Header: `humanName ?? name` (bold) + `· name` role subtitle (muted, small) when `humanName` is set; just `name` when not.
- Bio line: existing `skills` string, unchanged.
- Stats line: `"N tasks · X% success · Y★ avg"` — derived on read from `TaskRun`s where `agentId == self.id`:
  - success % over terminal runs (`succeeded`/`failed`)
  - avg rating over runs where `rating != nil` (unrated runs excluded, not treated as 0)
  - agents with zero runs show `"0 tasks"` and omit the success/rating segments
- Feed preview: last 2 completed runs inline, muted — `"<task title> · <relative time>"`.
- Tap → inline expand (reuses existing edit-toggle mechanism): expanded card shows full feed (last ~20 runs, scrollable, each row = task title + outcome icon + star rating if present + relative time, tap → jumps to that task) stacked above the existing editor fields. No separate sheet/tabs.
- No live status dot (explicitly out of scope).
- `dsBadge("built-in", ...)` unchanged.

`agentEditor(_:)` — one new field: `humanName` text input (optional, placeholder = role name). All existing fields (icon, model picker, skills, systemPrompt, tool allowlist, reset-to-shipped) unchanged.

Stats/feed computed by a small helper (e.g. on `TaskBoardSession` or a standalone `AgentStatsStore`) that filters `TaskRun` history by `agentId` — no new persistence layer, purely derived on read.

## 3. Rating

- `TaskDetailView`: once a run reaches a terminal state (succeeded/failed), a 5-star tappable control appears near the outcome. Rating is editable after the fact (re-tapping overwrites).
- Rating flows into the agent's stats line and into feed rows in the expanded profile card.

## Error handling

- No runs yet for an agent → stats/feed sections render empty/zero state, not hidden entirely.
- `humanName` absent → all name displays fall back to `name` (role), no nil-unwrap crashes.
- `rating` absent on a run → excluded from avg, run still shows in feed without a star.

## Testing

- `Scripts/build-app.sh` clean build.
- Launch and verify via AX tree (per `glance-launch-and-ax-verify` memory — no screen recording available in this terminal):
  - 5 built-ins render with human names + role subtitles.
  - Zero-run agent shows `"0 tasks"`, no success/rating segments.
  - Tap-expand shows feed + editor together, inline.
  - Custom agent with `humanName == nil` renders with role name only, no crash.
  - Rating a completed task in `TaskDetailView` updates the corresponding agent's stats line after reopening Settings.
