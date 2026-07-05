import SwiftUI

/// Momentum widget (canvas, bottom-right): today's completions fill a ring
/// toward a soft daily goal; the flame keeps the day-streak honest. Stats are
/// derived from completedAt stamps — nothing extra is persisted.
struct MomentumMeter: View {
    @ObservedObject var store: TaskStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Soft goal — a full ring, not a cap.
    private static let dailyGoal = 3

    var body: some View {
        let stats = store.momentumStats()
        HStack(spacing: DS.Space.sm) {
            ZStack {
                Circle()
                    .stroke(DS.surface, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: min(1, CGFloat(stats.doneToday) / CGFloat(Self.dailyGoal)))
                    .stroke(DS.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : DS.spring, value: stats.doneToday)
                Text("\(stats.doneToday)")
                    .font(DS.Typo.headline)
                    .foregroundStyle(DS.textPrimary)
                    .contentTransition(.numericText())
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(stats.doneToday == 1 ? "1 done today" : "\(stats.doneToday) done today")
                    .font(DS.Typo.label)
                    .foregroundStyle(DS.textPrimary)
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill")
                        .font(DS.Typo.overline)
                        .foregroundStyle(stats.currentStreak > 0 ? Color(hexRGB: "F59E0B")! : DS.textTertiary)
                    Text(streakLabel(stats))
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.textTertiary)
                }
            }
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.xs)
        .background(Capsule().fill(DS.bg)
            .shadow(color: DS.Shadow.card, radius: DS.Shadow.cardRadius, y: DS.Shadow.cardY))
        .overlay(Capsule().strokeBorder(DS.border, lineWidth: 1))
        .help("Best streak: \(store.momentumStats().bestStreak) day(s) · \(store.momentumStats().totalDone) done all-time")
    }

    private func streakLabel(_ stats: TaskStore.MomentumStats) -> String {
        stats.currentStreak > 0
            ? "\(stats.currentStreak)-day streak"
            : "no streak yet"
    }
}
