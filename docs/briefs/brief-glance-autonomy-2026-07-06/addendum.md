# Addendum — Glance Autonomy Layer

Depth that belongs downstream (PRD, architecture), not in the brief.

## Build order (dependency-ordered roadmap)

1. **Background ingest loop** — scheduler + dedupe on top of existing `ComposioIngest` + `WorkContext` cache.
2. **Auto-triage** — reuse CaptureCard "Create with AI" auto-fill path for incoming items.
3. **Review queue** — new `needsReview` task state in `TaskModels`, review UI in `TaskDetailView`, per-type approve actions (send Slack reply, post Jira comment) as the only write-capable Composio calls; `ComposioIngest` currently enforces read-only — write actions need an explicit, separately-gated escape hatch (a `runReadOnly()` public method already exists as precedent for controlled exceptions).
4. **Calendar-driven prep** — trigger `TaskAI.prepNotes()` from calendar proximity; notify via `TaskNotifications`.
5. **Post-meeting loop** — Granola transcript → action-item extraction → auto-create tasks.
6. **Daily briefing** (v2) — morning digest: today's meetings, top tasks, blocked items, drafts awaiting review.
7. **Feedback learning** (v2) — diff user edits vs AI drafts, feed into `AgentProfile` prompts.

Review queue (#3) is the keystone: everything upstream feeds it, and it embodies the trust boundary.

## Review-queue architecture options (from 2026 landscape research)

- **Synchronous gate** (pause + wait for approval) — max control, max latency. **Chosen for v1**: matches personal-tool stakes and the hard trust boundary.
- Async escalation (agent continues other work while one item waits) — natural fit later since TaskRunner already works per-task.
- Parallel feedback (execute while reviewing, rollback on reject) — rejected: outbound sends are not rollback-able.

## Landscape digest (2026)

- Draft-and-wait is the universal human gate across Lindy, Cora, Fyxer, Serif, alfred_ (email-centric assistants) — human clicks send.
- alfred_: overnight triage + morning Daily Brief linking inbox to calendar. Closest analogue to the v2 daily briefing.
- Meeting-prep triggers in the wild: scheduled cron (overnight) or calendar-event-based. ChatGPT Workspace Agents pull attendee context + web news for briefs.
- Platforms (Dust.tt, Notion Custom Agents, Copilot/Agent 365, Gemini Enterprise): enterprise, per-seat SaaS, event-triggered agents, permission models separating data access from action rights.
- Documented failure mode: **approval fatigue / "clickthrough vulnerability"** — past a volume threshold, humans reflex-approve. Mitigation adopted in the brief: only the five outbound actions queue for review; all internal actions run free.
- Governance warning signal: Gartner projects 40% of enterprises demote/decommission autonomous agents by 2027 over governance gaps. Design implication: keep reasoning inspectable in the review UI; scope access separately from action rights.

## Trust design principles (carried into PRD)

- Separate **access scope** (what the agents can read) from **action scope** (what they can do) — read stays broad, write stays behind the five-action gate.
- Every queued item shows: the draft, the source context it was built from, and the agent's reasoning.
- Review volume is a managed quantity: if the queue regularly exceeds what ~15 min/day can absorb, triage thresholds tighten rather than the user reading faster.
