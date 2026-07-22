import SwiftUI

/// Morning briefing panel (A1): a floating card over the board canvas showing
/// the latest AI-composed briefing — what arrived overnight, what's waiting in
/// Review, today's meetings, a suggested top-3, and the momentum line. The
/// briefing itself is generated on the Autopilot schedule (or the ↻ button)
/// and persisted in Preferences, so the panel always has the last one.
struct BriefingPanel: View {
    @ObservedObject var session: TaskBoardSession
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(DS.Space.md)
            Divider().overlay(DS.divider)
            ScrollView {
                content
                    .padding(DS.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 460)
        .frame(maxHeight: 540)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.large)
                .fill(DS.bg)
                .shadow(color: DS.Shadow.card, radius: DS.Shadow.cardHoverRadius,
                        y: DS.Shadow.cardHoverY)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.large)
                .strokeBorder(DS.border, lineWidth: 1)
        )
        .onExitCommand { session.showBriefing = false }
    }

    private var header: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "sun.max.fill")
                .font(DS.Typo.headline)
                .foregroundStyle(DS.accentText)
            Text("Morning briefing")
                .font(DS.Typo.title)
            if let at = prefs.briefingGeneratedAt {
                Text(at.formatted(date: .abbreviated, time: .shortened))
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.textTertiary)
            }
            Spacer()
            if session.briefingBusy {
                ProgressView().controlSize(.small)
            } else {
                headerIcon("arrow.clockwise", help: "Regenerate the briefing") {
                    session.generateBriefing()
                }
            }
            headerIcon("xmark", help: "Close") {
                session.showBriefing = false
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !prefs.briefingMD.isEmpty {
            MarkdownText(text: prefs.briefingMD, palette: .light)
                .font(DS.Typo.body)
        } else {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(session.briefingBusy ? "Writing your briefing…" : "No briefing yet")
                    .font(DS.Typo.headline)
                    .foregroundStyle(DS.textSecondary)
                if !session.briefingBusy {
                    Text("One lands here each workday at \(Self.timeLabel(minutes: prefs.briefingMinutes)) — or generate one now with ↻.")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.textTertiary)
                }
            }
        }
    }

    private func headerIcon(_ symbol: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Hover { hovering in
            Button(action: action) {
                Image(systemName: symbol)
                    .font(DS.Typo.label)
                    .foregroundStyle(hovering ? DS.textPrimary : DS.textSecondary)
                    .padding(DS.Space.xxs + 1)
                    .background(Circle().fill(hovering ? DS.surfaceHover : .clear))
            }
            .buttonStyle(.plain)
        }
        .help(help)
    }

    /// "09:00"-style label for minutes-since-midnight.
    static func timeLabel(minutes: Int) -> String {
        let comps = DateComponents(hour: minutes / 60, minute: minutes % 60)
        let date = Calendar.current.date(from: comps) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}
