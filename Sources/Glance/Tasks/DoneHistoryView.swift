import SwiftUI

/// The Done tab as a history screen: streak stats up top, completions grouped
/// by day, restore per row, and the bulk archive kept from the old list.
struct DoneHistoryView: View {
    @ObservedObject var session: TaskBoardSession
    @ObservedObject var store: TaskStore

    var body: some View {
        let tasks = session.visibleTasks()
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                statsHeader

                if tasks.contains(where: { $0.status == .done }) {
                    HStack {
                        Spacer()
                        Button(action: {
                            for t in tasks where t.status == .done {
                                store.setStatus(t.id, .archived)
                            }
                        }) {
                            Label("Archive all done", systemImage: "archivebox").font(DS.Typo.label)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.accentText)
                    }
                }

                if tasks.isEmpty {
                    VStack(spacing: DS.Space.xs) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 28))
                            .foregroundStyle(DS.textTertiary)
                        Text("Nothing finished yet")
                            .font(DS.Typo.headline)
                            .foregroundStyle(DS.textSecondary)
                        Text("Check off a task on the canvas and it lands here.")
                            .font(DS.Typo.caption)
                            .foregroundStyle(DS.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(DS.Space.xl)
                }

                ForEach(dayGroups(tasks), id: \.title) { group in
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(group.title.uppercased())
                            .font(DS.Typo.overline).tracking(0.8)
                            .foregroundStyle(DS.textTertiary)
                        VStack(spacing: DS.Space.xs) {
                            ForEach(group.tasks) { task in
                                row(task)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.bottom, DS.Space.lg)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Stats header

    private var statsHeader: some View {
        let stats = store.momentumStats()
        return HStack(spacing: DS.Space.md) {
            stat("\(stats.doneToday)", "today", icon: "checkmark.circle.fill", tint: DS.success)
            stat("\(stats.currentStreak)", stats.currentStreak == 1 ? "day streak" : "day streak",
                 icon: "flame.fill", tint: Color(hexRGB: "F59E0B")!)
            stat("\(stats.bestStreak)", "best streak", icon: "trophy.fill", tint: DS.accentText)
            stat("\(stats.totalDone)", "all-time", icon: "sum", tint: DS.textSecondary)
            Spacer()
        }
    }

    private func stat(_ value: String, _ label: String, icon: String, tint: Color) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: icon)
                .font(DS.Typo.headline)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(DS.textPrimary)
                    .contentTransition(.numericText())
                Text(label)
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.textTertiary)
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.xs + 2)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.surface))
    }

    // MARK: - Day groups

    private struct DayGroup {
        let title: String
        let tasks: [TaskItem]
    }

    private func dayGroups(_ tasks: [TaskItem]) -> [DayGroup] {
        let cal = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [TaskItem]] = [:]
        for t in tasks {
            let day = cal.startOfDay(for: t.completedAt ?? t.updatedAt)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(t)
        }
        return order.map { day in
            DayGroup(title: dayTitle(day, cal: cal), tasks: buckets[day] ?? [])
        }
    }

    private func dayTitle(_ day: Date, cal: Calendar) -> String {
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    // MARK: - Row

    private func row(_ task: TaskItem) -> some View {
        Hover { hovering in
            Button(action: { session.selectedTaskId = task.id }) {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle.slash")
                        .font(DS.Typo.headline)
                        .foregroundStyle(task.status == .done ? DS.success : DS.textTertiary)
                    Text(task.title)
                        .font(DS.Typo.body)
                        .foregroundStyle(DS.textPrimary)
                        .strikethrough(task.status == .done, color: DS.textTertiary)
                        .lineLimit(1)
                    if task.status != .done {
                        dsBadge(task.status.display, tint: DS.textSecondary, soft: DS.surfaceHover)
                    }
                    Spacer()
                    if let at = task.completedAt {
                        Text(at.formatted(date: .omitted, time: .shortened))
                            .font(DS.Typo.mono)
                            .foregroundStyle(DS.textTertiary)
                    }
                    if hovering {
                        Button(action: { store.setStatus(task.id, .ready) }) {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                                .font(DS.Typo.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.accentText)
                        .help("Back onto the canvas as Ready")
                    }
                }
                .padding(.horizontal, DS.Space.md)
                .padding(.vertical, DS.Space.xs + 2)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.medium)
                        .fill(hovering ? DS.surfaceHover : DS.bg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.medium)
                        .strokeBorder(DS.border.opacity(0.6), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.medium))
            }
            .buttonStyle(.plain)
        }
    }
}
