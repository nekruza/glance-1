import Foundation

/// Autonomy heartbeat, driven by AppCoordinator's minute tick. Stage 1 scope:
/// meeting prep — calendar tasks starting within the lead window get prep
/// notes generated automatically, plus a notification when the notes land.
/// Regeneration stays manual; each meeting fires at most once per launch.
@MainActor
final class Autopilot {

    /// Meetings we've kicked prep generation off for (this launch).
    private var prepRequested: Set<UUID> = []
    /// Meetings we've already posted a "prep ready" notification for.
    private var prepNotified: Set<UUID> = []
    /// Day we last ran the morning calendar safety pull for.
    private var calendarPullDay: Date?

    func tick(session: TaskBoardSession, notify: (String, UUID) -> Void) {
        let prefs = Preferences.shared
        guard prefs.prepAutopilotEnabled else { return }

        let now = Date()
        morningCalendarPull(session: session, now: now)

        let lead = TimeInterval(prefs.prepLeadMinutes * 60)
        for task in session.store.tasks {
            guard task.source == .calendar,
                  let start = task.dueAt,
                  start > now, start <= now + lead,
                  task.status != .done, task.status != .archived,
                  task.status != .cancelled else { continue }

            if let notes = task.prepNotes, !notes.isEmpty {
                // Notes landed for a prep we requested — tell the user once.
                if prepRequested.contains(task.id), !prepNotified.contains(task.id) {
                    prepNotified.insert(task.id)
                    notify("Prep ready — \(task.title)", task.id)
                }
            } else if !prepRequested.contains(task.id),
                      !session.prepBusyTaskIds.contains(task.id) {
                prepRequested.insert(task.id)
                session.generatePrepNotes(task)
            }
        }
    }

    /// Weekday-morning safety net: if nothing on today's board came from the
    /// calendar, pull it once so prep doesn't depend on a manual fetch.
    private func morningCalendarPull(session: TaskBoardSession, now: Date) {
        guard !Preferences.shared.composioKey.isEmpty,
              session.pullingSource == nil else { return }

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
