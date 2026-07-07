import SwiftUI

/// The Review tab: one unified queue for every task waiting on the human —
/// plan approvals, finished-run reviews, and outbound drafts. Each row carries
/// a gate-kind chip, a preview snippet, and the decision buttons; tapping a row
/// opens the full detail view for editing. Outbound sends stay behind an
/// explicit per-row "Approve & send" — nothing leaves the machine otherwise.
struct ReviewQueueView: View {
    @ObservedObject var session: TaskBoardSession
    @ObservedObject var store: TaskStore

    /// What a queued task is waiting for — drives the chip + which buttons show.
    private enum Gate {
        case plan          // awaiting plan approval (a run is queued to execute)
        case runReview     // a finished run's result awaits review
        case draft         // an outbound/helper draft awaits send/approve

        var label: String {
            switch self {
            case .plan: return "Plan"
            case .runReview: return "Run review"
            case .draft: return "Draft"
            }
        }
        var icon: String {
            switch self {
            case .plan: return "list.bullet.rectangle"
            case .runReview: return "flag.checkered"
            case .draft: return "paperplane"
            }
        }
    }

    var body: some View {
        let tasks = session.visibleTasks()
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                if tasks.isEmpty {
                    emptyState
                } else {
                    Text("Everything waiting on you — approve, edit, or reject. Nothing sends until you say so.")
                        .font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
                    ForEach(tasks) { task in
                        row(task, gate: gate(for: task))
                    }
                }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.bottom, DS.Space.lg)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Gate classification

    /// A finished run parks the task at `awaitingReview` with the run at
    /// `.succeeded`; a draft gate has a helper draft and no such run. Anything
    /// else (stale run state, no draft) falls back to run review so a task
    /// never shows send buttons for a draft it doesn't have.
    private func gate(for task: TaskItem) -> Gate {
        if task.status == .awaitingPlanApproval { return .plan }
        if store.runs(for: task.id).first?.state == .succeeded { return .runReview }
        return task.helperDraft != nil ? .draft : .runReview
    }

    private func snippet(_ task: TaskItem, gate: Gate) -> String {
        switch gate {
        case .plan:
            return store.runs(for: task.id).first?.plan ?? ""
        case .runReview:
            let artifacts = store.runs(for: task.id).first?.artifacts ?? []
            return artifacts.map(\.summary).joined(separator: " · ")
        case .draft:
            return task.helperDraft ?? ""
        }
    }

    // MARK: - Row

    private func row(_ task: TaskItem, gate: Gate) -> some View {
        Hover { hovering in
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.xs) {
                    dsBadge(gate.label, tint: DS.accentText, soft: DS.accentSoft)
                    Image(systemName: task.source.icon)
                        .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
                    Text(task.title)
                        .font(DS.Typo.body).fontWeight(.medium)
                        .foregroundStyle(DS.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.textTertiary)
                        .opacity(hovering ? 1 : 0)
                }
                let preview = snippet(task, gate: gate)
                if !preview.isEmpty {
                    Text(preview)
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                actions(task, gate: gate)
            }
            .padding(DS.Space.sm)
            .background(RoundedRectangle(cornerRadius: DS.Radius.medium)
                .fill(hovering ? DS.surfaceHover : DS.bg))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium)
                .strokeBorder(DS.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.medium))
            .onTapGesture { session.selectedTaskId = task.id }
        }
    }

    // MARK: - Actions (per gate)

    @ViewBuilder private func actions(_ task: TaskItem, gate: Gate) -> some View {
        let runId = store.runs(for: task.id).first?.id
        let canSend = gate == .draft && task.outboundTarget != nil
        // Once a send is in flight the message may already be out — freeze
        // every decision button, not just the send one.
        let sending = session.sendBusyTaskIds.contains(task.id)
        HStack(spacing: DS.Space.xs) {
            Button("Reject") { reject(task, gate: gate, runId: runId) }
                .buttonStyle(DSSecondaryButtonStyle())
                .foregroundStyle(DS.danger)
                .disabled(sending)
            Spacer()
            // When a send is offered, plain Approve is the quieter secondary.
            if canSend {
                Button("Approve") { approve(task, gate: gate, runId: runId) }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .disabled(sending)
                Button(action: { session.approveSend(task, editedDraft: nil) }) {
                    HStack(spacing: DS.Space.xxs) {
                        if session.sendBusyTaskIds.contains(task.id) {
                            ProgressView().controlSize(.small)
                            Text("Sending…")
                        } else {
                            Label("Approve & send", systemImage: "paperplane.fill")
                        }
                    }
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(session.sendBusyTaskIds.contains(task.id))
                .help("Post to the exact Slack thread / Jira issue this came from")
            } else {
                Button("Approve") { approve(task, gate: gate, runId: runId) }
                    .buttonStyle(DSPrimaryButtonStyle())
            }
        }
    }

    private func approve(_ task: TaskItem, gate: Gate, runId: UUID?) {
        switch gate {
        case .plan:
            if let runId { session.runner.approvePlan(runId: runId, guidance: nil) }
        case .runReview:
            if let runId { session.runner.approveReview(runId: runId, releaseBoundary: false) }
        case .draft:
            session.approveDraft(task)
        }
    }

    private func reject(_ task: TaskItem, gate: Gate, runId: UUID?) {
        switch gate {
        case .plan:
            if let runId { session.runner.rejectPlan(runId: runId, reason: "") }
        case .runReview:
            if let runId { session.runner.rejectReview(runId: runId, reason: "") }
        case .draft:
            session.rejectDraft(task)
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: DS.Space.xs) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 28))
                .foregroundStyle(DS.textTertiary)
            Text("Nothing needs you")
                .font(DS.Typo.headline)
                .foregroundStyle(DS.textSecondary)
            Text("Plans, finished runs and drafts waiting on your call land here.")
                .font(DS.Typo.caption)
                .foregroundStyle(DS.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Space.xl)
    }
}
