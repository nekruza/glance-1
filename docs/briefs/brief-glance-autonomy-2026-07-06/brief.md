---
title: "Product Brief: Glance Autonomy Layer"
status: approved
created: 2026-07-06
updated: 2026-07-06
---

# Product Brief: Glance Autonomy Layer

## Executive Summary

Glance today is a macOS menu-bar assistant that helps on demand: it ingests work context from Slack, Jira, GitHub, and Granola, keeps tasks on a spatial canvas, and generates AI drafts and meeting prep notes — but only when asked. Every loop still starts and ends with the user.

The Autonomy Layer closes that loop. Glance will continuously ingest work signals in the background, triage them into prioritized tasks, execute the work with AI agents, and park every finished draft in a review queue. The user's job shrinks to one verb: **review**. Nothing outbound — no Slack message, email, Jira comment, or meeting acceptance — ever leaves the machine without an explicit human approval.

The outcome this buys: walking into every meeting fully prepared, and completing every task to a standard the user is proud of — with the user's hands-on time spent on judgment, not production.

## The Problem

Work context lives in five places (Slack, Jira, GitHub, email, calendar/meetings) and none of them talk to each other. Turning that noise into finished work today means: notice the signal, decide it matters, open Glance, trigger the right helper, wait, then polish and send. Each step is small; together they eat the day. Meeting prep competes with everything else and loses — prep happens in the two minutes before the call, or not at all.

The current Glance removes the *production* effort but not the *initiation* effort. The user is still the scheduler, dispatcher, and trigger for every piece of AI work. [ASSUMPTION] The initiation overhead — noticing, deciding, triggering — is the dominant remaining time leak, bigger than the review effort that would replace it.

## The Solution

A closed pipeline with one human gate:

1. **Ingest** — Glance polls Slack, Jira, GitHub, and Granola on a schedule in the background, deduplicates against existing tasks, and files new actionable items into the inbox. No manual fetch.
2. **Triage** — AI ranks and enriches each new item (kind, priority, due date, agent, model) using the same auto-fill intelligence as the capture card. The inbox arrives pre-sorted.
3. **Execute** — TaskRunner works eligible tasks unprompted: drafts the Slack reply, writes the Jira comment, prepares the brief. Calendar-triggered prep notes generate automatically before each meeting; post-meeting, Granola transcripts are mined for action items that become new tasks.
4. **Review** — every outbound artifact lands in a `needsReview` queue showing the draft, the source context, and the agent's reasoning. The user approves (Glance sends it), edits then approves, or rejects. This is the only step that requires the human.

**Hard trust boundary** — five actions are never autonomous: sending a Slack message, sending a reply, posting a Jira comment, sending an email, accepting a meeting invite. Everything else (labeling, task creation, prioritization, prep-note generation, drafting) runs without approval, keeping review volume low enough that approvals stay meaningful — the antidote to approval fatigue.

## What Makes This Different

The 2026 landscape (Lindy, Cora, Fyxer, alfred_, Dust, Notion Agents, Copilot Agent 365) is cloud SaaS, email-centric or enterprise-platform shaped. Nothing found operates as a **local-first macOS app driving a local Claude CLI** with the user's own credentials and screen awareness. Work context never transits a third-party autonomy vendor; there is no per-seat subscription; the review gate lives on-device. The honest moat is fit, not technology: this is built for exactly one user's stack and workflow.

## Who This Serves

One user: a knowledge worker whose job runs on Slack, Jira, GitHub, email, and meetings, who wants to perform at the top of their team. Success for them: showing up sharp to every meeting, turning work around fast and excellently, and spending attention on decisions instead of production. No secondary users; no multi-tenant concerns.

## Success Criteria

[ASSUMPTION — all four, correct freely]

- **Zero unprepped meetings**: prep notes ready and surfaced before every calendar meeting, without being asked.
- **Same-day drafts**: every actionable inbox item has a reviewed-ready draft within the working day it arrives.
- **Review stays cheap**: total daily review time under ~15 minutes; approval rate stays high (drafts usually good enough to send with light edits).
- **Felt difference**: within a month, the user notices meetings feel easier and task turnaround is visibly faster than before the Autonomy Layer.

## Scope

**In (v1):**
- Background ingest loop with scheduling and dedupe
- AI auto-triage of new inbox items
- Autonomous TaskRunner execution into a `needsReview` state + review queue UI (approve / edit / reject, with send-on-approve for the five gated actions)
- Calendar-triggered meeting prep notes with notification
- Post-meeting action-item extraction from Granola transcripts

**Out (v1):**
- Auto-sending anything — the five gated actions always require approval, permanently in spirit, absolutely in v1
- Daily morning briefing digest [ASSUMPTION: v2 — valuable but not on the critical path to the closed loop]
- Feedback learning from user edits (v2)
- Multi-user, cloud sync, mobile, non-macOS

## Vision

Glance becomes a genuine chief of staff: it learns from every edit the user makes to its drafts, tunes its agents per task type, and briefs the user each morning on what it did overnight and what needs their judgment today. The user operates as editor-in-chief of their own job — the work arrives finished, the human supplies taste and accountability. The approval gate never disappears; it just gets quieter as trust is earned per action type.
