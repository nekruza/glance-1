---
title: 'Glance Autonomy Layer v1 — auto-triage, draft autopilot, review queue, post-meeting extraction'
type: 'feature'
created: '2026-07-06'
status: 'done'
baseline_commit: '4922baffdba905e481da422860ad63dfc9776e93'
context:
  - '{project-root}/docs/briefs/brief-glance-autonomy-2026-07-06/brief.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Glance ingests work signals and drafts AI output, but the user must trigger every step; drafts never leave the app, and human gates are scattered (per-task detail view, notifications) with no single review surface.

**Approach:** Close the loop: auto-triage pulled inbox items, let Autopilot generate outbound drafts (Slack replies, Jira comments) unprompted, surface all human gates in one Review tab, and on explicit approval perform the single gated write via Composio. Feed local meeting transcripts into action-item extraction.

## Boundaries & Constraints

**Always:**
- The five outbound actions (send Slack message, send reply, post Jira comment, send email, accept meeting) execute ONLY from an explicit user approval click. Approval applies to exactly one action on one task.
- Write prompts to Composio must instruct exactly one named action and must not include broad permissions; read paths keep `readOnlyRules` untouched.
- Every autonomous behavior gets a Preferences toggle; defaults on for triage/prep, on for draft autopilot.
- Match existing code style (DesignTokens, sectionCard patterns, @MainActor session mutations, store.update persistence).

**Ask First:**
- Any new Composio meta-tool added to the `--allowedTools` list.
- Auto-sending anything without a per-item approval (e.g. "auto-approve low-risk") — out of v1, renegotiate.

**Never:**
- No email sending or meeting-invite acceptance implementation in v1 (no Composio email/calendar-write prompts) — gate design must not preclude them later.
- No auto-approve, no batch-approve-all button.
- Do not modify TaskRunner boundary-action enforcement (git push / gh pr deny rules).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Auto-triage | Pull inserts N new inbox tasks | Each new task enriched (empty fields only), aiFilledFields appended | Enrich failure → task stays raw inbox; no retry loop |
| Draft autopilot | Accepted slack/jira task, no helperDraft, autopilot on | Draft generated, task → `.awaitingReview`, one notification | Draft failure → task stays `.ready`; retried next launch only |
| Approve & send (Slack) | awaitingReview slack task w/ sourceRef permalink, user clicks Approve & send | performWrite posts reply to that thread; on DONE → sentAt set, task `.done` | FAILED/timeout → task stays `.awaitingReview`, error surfaced, no retry |
| Approve & send (Jira) | awaitingReview jira task w/ issue key | Comment posted to that issue; task `.done` | same as Slack |
| Approve w/o target | awaitingReview task, helper brief/approach (no outbound) | "Approve" marks `.done`; no Composio call | N/A |
| Edit then send | User edits draft text, clicks Approve & send | Edited text is what's sent; helperDraft updated first | same as send |
| Reject draft | User clicks Reject | Task → `.ready`, draft kept for reference | N/A |
| Missing sourceRef | Slack task w/o permalink | Send button disabled with hint; plain Approve still works | N/A |
| Post-meeting extraction | MeetingTranscriber finishes summary | extractActionItems on transcript → inbox tasks, source `.granola`, sourceRef.key = transcript filename + index | Extraction failure → log only, transcript untouched |
| Re-extraction dedupe | Same transcript processed twice | Existing sourceRef keys skipped | N/A |
| No Composio key | composioKey empty | Autopilot draft/triage skip silently; send buttons hidden | N/A |

</frozen-after-approval>

## Code Map

- `Sources/Glance/Tasks/TaskModels.swift` -- TaskItem (add sentAt), TaskStatus (`.awaitingReview` reused for draft review), TaskHelper mapping :156, SourceRef :229
- `Sources/Glance/Tasks/ComposioIngest.swift` -- read-only prompts, `run()` :138 subprocess, `readOnlyRules` :279, pull dedupe :59-72; add `performWrite`
- `Sources/Glance/Tasks/TaskBoardSession.swift` -- Tab enum, `createTask` :284, private `enrich` :340, `generateHelperDraft`, pull :131; add triage + send methods
- `Sources/Glance/Tasks/Autopilot.swift` -- minute tick; extend with draft autopilot
- `Sources/Glance/Settings/Preferences.swift` -- pref pattern (prepAutopilotEnabled) to copy
- `Sources/Glance/Tasks/TabPill.swift` -- tabs :87, counts; add Review
- `Sources/Glance/Tasks/TaskBoardView.swift` -- tab switch :28; route Review tab
- `Sources/Glance/Tasks/TaskDetailView.swift` -- body status switch :67, reviewGate :788 (run-based), sectionCard :671; add draft-review block
- `Sources/Glance/Tasks/TaskAI.swift` -- `extractActionItems` :311, `helperDraft` :244, `runRaw` :351
- `Sources/Glance/Transcribe/MeetingTranscriber.swift` -- `summarize()` :359 writes notes; add completion hook
- `Sources/Glance/AppCoordinator.swift` -- autopilot tick wiring :180, notification callbacks :115
- `Sources/Glance/Tasks/TaskSettingsView.swift` -- settings toggles

## Tasks & Acceptance

**Execution:**
- [x] `Preferences.swift` -- add `autoTriageEnabled` (default true), `draftAutopilotEnabled` (default true) following prepAutopilot pattern -- toggles per Always rule
- [x] `TaskModels.swift` -- add `sentAt: Date?` to TaskItem; add computed `outboundTarget: OutboundTarget?` (slackReply(permalink) / jiraComment(issueKey), nil otherwise) derived from source+sourceRef -- single source of truth for send eligibility
- [x] `ComposioIngest.swift` -- add `performWrite(instruction: String, completion: (Result<Void,Error>) -> Void)`: same subprocess/allowlist as run(), prompt = strict single-action rules ("execute exactly this one write action, nothing else, reply DONE or FAILED: reason") + instruction; NO readOnlyRules. Also: make `pull` completion report the new task IDs -- triage needs them
- [x] `TaskBoardSession.swift` -- (a) post-pull auto-triage: when autoTriageEnabled, run existing enrich on each new inbox task; (b) `approveSend(_ task:, editedDraft: String?)`: persist edit, build instruction from outboundTarget + draft, call performWrite, on success sentAt/.done/notify, on failure keep state + surface error; (c) `rejectDraft(_ task:)` → `.ready`; (d) published `sendBusyTaskIds: Set<UUID>`
- [x] `Autopilot.swift` -- draft autopilot in tick(): tasks with status `.ready`/`.inbox`, source slack or jira, helperDraft nil, helper in {reply, draft, approach}, not draftBusy → call session.generateHelperDraft once per task per launch; when draft lands set status `.awaitingReview` + notify "Draft ready — <title>"
- [x] `TaskBoardSession.swift` + `TabPill.swift` + `TaskBoardView.swift` -- add `Tab.review` between inbox and done; count = tasks in `.awaitingPlanApproval` + `.awaitingReview`; route to ReviewQueueView
- [x] `Tasks/ReviewQueueView.swift` (new) -- unified queue list: row per gated task (gate kind chip: Plan / Run review / Draft; title; preview snippet; Approve / Reject buttons; draft rows also "Approve & send" when outboundTarget != nil); tap row → open detail; empty state "Nothing needs you"
- [x] `TaskDetailView.swift` -- for `.awaitingReview` tasks with no active run gate: draft-review block (editable TextEditor bound to helperDraft, Approve & send / Approve / Reject buttons wired to session methods, busy spinner via sendBusyTaskIds)
- [x] `MeetingTranscriber.swift` + `AppCoordinator.swift` -- post-summarize hook: pass transcript text to TaskAI.extractActionItems; create inbox tasks (`createTask` enrich:false, then mark source `.granola`, sourceRef.key = "<transcript-filename>#<index>") skipping existing keys
- [x] `TaskSettingsView.swift` -- toggles: Auto-triage new items, Draft autopilot (near existing prep autopilot toggle)
- [x] Build `Scripts/build-app.sh` + launch; verify via AX tree (Review tab present, counts correct)

**Acceptance Criteria:**
- Given a scheduled pull inserts new items and autoTriageEnabled, when the pull completes, then each new inbox task gains AI-filled kind/labels/description without touching user-entered fields.
- Given an accepted Slack task with a permalink and draftAutopilotEnabled, when Autopilot ticks, then a reply draft is generated exactly once and the task appears in the Review tab.
- Given a task in the Review tab with a draft, when the user edits the text and clicks Approve & send, then the edited text is posted to the exact Slack thread / Jira issue from sourceRef, and only then does the task become done with sentAt set.
- Given performWrite returns FAILED, when approving a send, then the task remains awaitingReview and the failure reason is visible.
- Given the app is fully quit and relaunched, then no draft is re-generated for tasks that already have helperDraft, and no send ever fires without a fresh click.
- Given a finished local meeting recording, when summarize completes, then action items appear as inbox tasks once, deduped on re-run.

## Spec Change Log

## Design Notes

- Reuse `.awaitingReview` for draft gates: detail view disambiguates by "has active run awaiting review" (run gate) vs "helperDraft != nil, no run" (draft gate). Avoids a new persisted status.
- performWrite reuses the existing 4-meta-tool allowlist — writes were always technically possible; safety = prompt scope + app-level approval gate. Instruction must embed the concrete target (permalink/issue key) and full final text.
- Autopilot per-launch memory (existing prepRequested pattern) is the retry-throttle for drafts too.

## Verification

**Commands:**
- `Scripts/build-app.sh` -- expected: BUILD SUCCEEDED, zero new warnings
- relaunch app bundle (open, not raw binary) -- expected: menu bar item up

**Manual checks (if no CLI):**
- AX tree: Review tab pill with count; queue rows expose Approve/Reject buttons; Slack task without permalink shows disabled send.
- Toggle prefs off → Autopilot skips triage/drafts on next tick.

## Suggested Review Order

**Trust boundary — the gated outbound write**

- Single write path: strict single-action prompt, DONE-last-line success parsing, no readOnlyRules
  [`ComposioIngest.swift:110`](../../Sources/Glance/Tasks/ComposioIngest.swift#L110)

- The only caller: persists edit first, builds the one instruction, success → sentAt/.done
  [`TaskBoardSession.swift:498`](../../Sources/Glance/Tasks/TaskBoardSession.swift#L498)

- Send eligibility derived once: Slack prefers the url (real permalink) over the dedupe key
  [`TaskModels.swift:172`](../../Sources/Glance/Tasks/TaskModels.swift#L172)

**Draft autopilot (autonomous generation, human-gated send)**

- Ready-only kick-off, once per task per launch; never touches performWrite
  [`Autopilot.swift:68`](../../Sources/Glance/Tasks/Autopilot.swift#L68)

- Draft persists and parks at Review in one store write — relaunch can't strand it
  [`TaskBoardSession.swift:454`](../../Sources/Glance/Tasks/TaskBoardSession.swift#L454)

**Review queue surface**

- New unified queue: gate classification with safe fallback (no send buttons without a draft)
  [`ReviewQueueView.swift:60`](../../Sources/Glance/Tasks/ReviewQueueView.swift#L60)

- Detail-view draft gate: editable buffer, all buttons freeze while a send is in flight
  [`TaskDetailView.swift:816`](../../Sources/Glance/Tasks/TaskDetailView.swift#L816)

- Run-gate vs draft-gate disambiguation mirrors the queue's
  [`TaskDetailView.swift:798`](../../Sources/Glance/Tasks/TaskDetailView.swift#L798)

- Fourth tab wired: Inbox · Board · Review · Done
  [`TaskBoardSession.swift:12`](../../Sources/Glance/Tasks/TaskBoardSession.swift#L12)

**Auto-triage**

- Post-pull enrich of exactly the new task IDs; fills empty fields only
  [`TaskBoardSession.swift:481`](../../Sources/Glance/Tasks/TaskBoardSession.swift#L481)

**Post-meeting extraction**

- onSummarized fires on every finalize path (success, no-CLI, spawn failure)
  [`MeetingTranscriber.swift:163`](../../Sources/Glance/Transcribe/MeetingTranscriber.swift#L163)

- Slugged per-item dedupe keys survive re-extraction reordering
  [`AppCoordinator.swift:238`](../../Sources/Glance/AppCoordinator.swift#L238)

**Peripherals**

- Two new prefs, default on, persisted
  [`Preferences.swift:137`](../../Sources/Glance/Settings/Preferences.swift#L137)

- Settings toggles for both autopilot behaviors
  [`TaskSettingsView.swift:644`](../../Sources/Glance/Tasks/TaskSettingsView.swift#L644)
