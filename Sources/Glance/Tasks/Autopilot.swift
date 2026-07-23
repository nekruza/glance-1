import Foundation

/// Autonomy heartbeat, driven by AppCoordinator's minute tick. Stage 1 scope:
/// meeting prep — calendar tasks starting within the lead window get prep
/// notes generated automatically, plus a notification when the notes land.
/// Regeneration stays manual; each meeting fires at most once per launch.
@MainActor
final class Autopilot {

    /// Meetings we've kicked prep generation off for (this launch).
    private var prepRequested: Set<UUID> = []
    /// Meetings we've warmed the WorkContext digest cache for (this launch).
    private var contextWarmRequested: Set<UUID> = []
    /// Meetings we've already posted a "prep ready" notification for.
    private var prepNotified: Set<UUID> = []
    /// Day we last ran the morning calendar safety pull for.
    private var calendarPullDay: Date?
    /// Tasks we've kicked draft generation off for (this launch) — the
    /// retry-throttle: a failed draft is retried only on next launch.
    private var draftRequested: Set<UUID> = []

    func tick(session: TaskBoardSession, notify: (String, UUID) -> Void) {
        let prefs = Preferences.shared
        if prefs.briefingEnabled {
            briefingTick(session: session)
        }
        if prefs.prepAutopilotEnabled {
            prepTick(session: session, notify: notify)
        }
        // Drafting is pointless without Composio (nothing to send) — skip
        // silently, matching triage/send behaviour when the key is absent.
        if prefs.draftAutopilotEnabled, !prefs.composioKey.isEmpty {
            draftTick(session: session)
        }
    }

    // MARK: - Morning briefing (A1, its own pref)

    /// Workday mornings at the configured time: compose the briefing once
    /// (lastRun gate, same shape as scheduled pulls) and notify when it lands.
    /// Composition itself is purely local — but if today's calendar hasn't
    /// been pulled yet (late wake: the 7–12h safety pull hasn't fired), pull
    /// it first and compose in the completion, so the briefing's "Today's
    /// meetings" section isn't composed from yesterday's board.
    private func briefingTick(session: TaskBoardSession) {
        guard !session.briefingBusy else { return }
        let prefs = Preferences.shared
        let now = Date()
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: now)
        guard weekday != 1, weekday != 7 else { return }

        let todayAt = cal.startOfDay(for: now)
            .addingTimeInterval(TimeInterval(prefs.briefingMinutes * 60))
        let last = prefs.briefingLastRun ?? .distantPast
        guard now >= todayAt, last < todayAt else { return }

        let today = cal.startOfDay(for: now)
        let hasTodayMeeting = session.store.tasks.contains {
            $0.source == .calendar && $0.dueAt.map { cal.isDate($0, inSameDayAs: now) } == true
        }
        let needsCalendarFirst = !hasTodayMeeting
            && calendarPullDay != today
            && !session.isPulling
            && !prefs.composioKey.isEmpty
            && prefs.isFetchEnabled(ComposioIngest.Source.calendar)

        prefs.briefingLastRun = now
        if needsCalendarFirst {
            // Claim the morning pull so prepTick doesn't fire a second one.
            calendarPullDay = today
            session.pull(.calendar) { [weak session] in
                session?.generateBriefing(notify: true)
            }
        } else {
            session.generateBriefing(notify: true)
        }
    }

    // MARK: - Meeting prep (its own pref)

    private func prepTick(session: TaskBoardSession, notify: (String, UUID) -> Void) {
        let now = Date()
        morningCalendarPull(session: session, now: now)

        let lead = TimeInterval(Preferences.shared.prepLeadMinutes * 60)
        // Digests stay fresh for the WorkContext TTL, so fetching them any
        // time inside that window costs nothing extra — start the gather as
        // early as the TTL allows and prep generation at lead time (or the
        // user opening the task) skips the "Gathering context…" wait.
        let warmHorizon = max(lead, WorkContext.ttl)
        for task in session.store.tasks {
            guard task.source == .calendar,
                  let start = task.dueAt,
                  start > now, start <= now + warmHorizon,
                  task.status != .done, task.status != .archived,
                  task.status != .cancelled else { continue }

            if let notes = task.prepNotes, !notes.isEmpty {
                // Notes landed for a prep we requested — tell the user once.
                if prepRequested.contains(task.id), !prepNotified.contains(task.id) {
                    prepNotified.insert(task.id)
                    notify("Prep ready — \(task.title)", task.id)
                }
            } else if start <= now + lead {
                if !prepRequested.contains(task.id),
                   !session.prepBusyTaskIds.contains(task.id) {
                    prepRequested.insert(task.id)
                    session.generatePrepNotes(task)
                }
            } else if !contextWarmRequested.contains(task.id) {
                contextWarmRequested.insert(task.id)
                session.workContext.digests { _ in }
            }
        }
    }

    // MARK: - Draft autopilot (its own pref)

    /// Generate the outbound draft for accepted Slack/Jira tasks that don't
    /// have one yet; the session parks them in Review the moment the draft
    /// persists (same store write — a relaunch can't strand a finished draft).
    /// Ready-only: Inbox items stay untouched until the user accepts them.
    /// Each task fires at most once per launch (draftRequested); regeneration
    /// and, crucially, sending stay manual — nothing here calls performWrite.
    private func draftTick(session: TaskBoardSession) {
        for task in session.store.tasks {
            guard task.helperDraft == nil,
                  task.status == .ready,
                  task.source == .slack || task.source == .jira,
                  [.reply, .draft, .approach].contains(task.helper),
                  !draftRequested.contains(task.id),
                  !session.draftBusyTaskIds.contains(task.id) else { continue }

            draftRequested.insert(task.id)
            session.generateHelperDraft(task, thenReview: true)
        }
    }

    /// Weekday-morning safety net: if nothing on today's board came from the
    /// calendar, pull it once so prep doesn't depend on a manual fetch.
    private func morningCalendarPull(session: TaskBoardSession, now: Date) {
        guard !Preferences.shared.composioKey.isEmpty,
              !session.isPulling else { return }

        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard calendarPullDay != today else { return }

        let weekday = cal.component(.weekday, from: now)
        let hour = cal.component(.hour, from: now)
        guard weekday != 1, weekday != 7, (7..<12).contains(hour) else { return }

        let hasTodayMeeting = session.store.tasks.contains {
            $0.source == .calendar && $0.dueAt.map { cal.isDate($0, inSameDayAs: now) } == true
        }
        guard !hasTodayMeeting else { calendarPullDay = today; return }

        calendarPullDay = today
        session.pull(.calendar)
    }
}
