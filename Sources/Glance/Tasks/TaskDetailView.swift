import SwiftUI

/// Task detail (FR24) + the two gates: plan approval (FR44.2) and review
/// (FR52–53). Shown inside the board panel when a task is selected.
struct TaskDetailView: View {
    @ObservedObject var session: TaskBoardSession
    let task: TaskItem

    @State private var guidance = ""
    @State private var rejectReason = ""
    @State private var editingDescription = false
    @State private var draftDescription = ""

    private var run: TaskRun? { session.selectedRun }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    titleBlock
                    metaRow
                    descriptionBlock

                    switch task.status {
                    case .awaitingPlanApproval: planGate
                    case .planning: workingRow("Planning…")
                    case .executing: executionStream
                    case .awaitingReview: reviewGate
                    case .failed: failureBlock
                    default: EmptyView()
                    }

                    runHistory
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Chrome

    private var headerBar: some View {
        HStack {
            Button(action: { session.selectedTaskId = nil }) {
                Label("Board", systemImage: "chevron.left").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.muted)
            Spacer()
            if task.isRunnable {
                Button(action: { session.run(task) }) {
                    Label("Run with AI", systemImage: "play.fill").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(task.taskKind == .code && (task.workspacePath ?? "").isEmpty)
                .help(task.taskKind == .code && (task.workspacePath ?? "").isEmpty
                      ? "Set a repo first (code task)" : "Plan → approve → execute")
            }
            if task.status == .executing || task.status == .planning {
                Button(action: { if let r = run { session.runner.cancelRun(runId: r.id) } }) {
                    Label("Cancel", systemImage: "stop.fill").font(.system(size: 12))
                        .foregroundStyle(Theme.danger)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
        .overlay(Divider().overlay(Theme.glassBorder), alignment: .bottom)
    }

    private var titleBlock: some View {
        HStack(spacing: 8) {
            Image(systemName: task.source.icon).font(.system(size: 13)).foregroundStyle(Theme.faint)
            Text(task.title).font(.system(size: 15, weight: .semibold))
        }
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            chip(task.aiPriority.rawValue)
            chip(task.status.display)
            chip(task.taskKind.rawValue)
            if let e = task.estimate { chip("~\(e.rawValue)") }
            ForEach(task.labels, id: \.self) { chip($0) }
            Spacer()
            repoPicker
        }
    }

    private var repoPicker: some View {
        Menu {
            ForEach(Preferences.shared.repos) { repo in
                Button(repo.name) {
                    var t = task
                    t.workspacePath = repo.path
                    session.store.update(t)
                }
            }
            if Preferences.shared.repos.isEmpty {
                Text("Add repos in Settings")
            }
            if task.workspacePath != nil {
                Divider()
                Button("Clear") {
                    var t = task
                    t.workspacePath = nil
                    session.store.update(t)
                }
            }
        } label: {
            let name = Preferences.shared.repos.first { $0.path == task.workspacePath }?.name
            Label(name ?? "repo…", systemImage: "folder")
                .font(.system(size: 11)).foregroundStyle(name == nil ? Theme.faint : Theme.muted)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var descriptionBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("DESCRIPTION").font(.system(size: 10, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(Theme.faint)
                if task.aiFilledFields.contains("description") {
                    Image(systemName: "sparkle").font(.system(size: 8)).foregroundStyle(Theme.accent)
                        .help("AI-filled — edit freely, your version wins")
                }
                Spacer()
                Button(editingDescription ? "Save" : "Edit") {
                    if editingDescription {
                        var t = task
                        t.descriptionMD = draftDescription
                        session.store.update(t)
                    } else {
                        draftDescription = task.descriptionMD
                    }
                    editingDescription.toggle()
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
            }
            if editingDescription {
                TextEditor(text: $draftDescription)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(height: 100)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            } else if task.descriptionMD.isEmpty {
                Text("No description").font(.system(size: 12)).foregroundStyle(Theme.faint)
            } else {
                MarkdownText(text: task.descriptionMD).font(.system(size: 12))
            }
        }
    }

    // MARK: - Plan gate (FR44.2)

    private var planGate: some View {
        gateBox(title: "PLAN — YOUR APPROVAL NEEDED", tint: .orange) {
            if let plan = run?.plan {
                MarkdownText(text: plan).font(.system(size: 12))
            }
            TextField("", text: $guidance,
                      prompt: Text("Optional guidance to append…").foregroundColor(Theme.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
            HStack {
                Button("Reject") {
                    if let r = run { session.runner.rejectPlan(runId: r.id, reason: guidance) }
                    guidance = ""
                }
                .foregroundStyle(Theme.danger)
                Spacer()
                Button("Approve & execute") {
                    if let r = run {
                        session.runner.approvePlan(runId: r.id,
                                                   guidance: guidance.isEmpty ? nil : guidance)
                    }
                    guidance = ""
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Execution stream (FR44.3)

    private var executionStream: some View {
        gateBox(title: "RUNNING", tint: Theme.accent) {
            workingRow("Agent working in \(run?.branchName ?? "scratch")…")
            if let tail = run?.progressTail, !tail.isEmpty {
                Text(tail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.codeBg))
            }
        }
    }

    // MARK: - Review gate (FR52–53)

    private var reviewGate: some View {
        gateBox(title: "REVIEW — RESULT READY", tint: .orange) {
            if let run {
                ForEach(run.artifacts) { artifact in
                    artifactRow(artifact, run: run)
                }
            }
            TextField("", text: $rejectReason,
                      prompt: Text("Rejection reason / retry guidance…").foregroundColor(Theme.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
            HStack {
                Button("Reject") {
                    if let r = run { session.runner.rejectReview(runId: r.id, reason: rejectReason) }
                    rejectReason = ""
                }
                .foregroundStyle(Theme.danger)
                Spacer()
                Button("Approve") {
                    if let r = run { session.runner.approveReview(runId: r.id, releaseBoundary: false) }
                }
                .help("Accept the work. Boundary actions (push/PR) stay individually gated below.")
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func artifactRow(_ artifact: RunArtifact, run: TaskRun) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: artifactIcon(artifact.kind))
                .font(.system(size: 11)).foregroundStyle(artifact.boundary ? .orange : Theme.muted)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.summary).font(.system(size: 11.5))
                if artifact.kind == .draftText {
                    Text(artifact.payloadRef)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(8)
                        .textSelection(.enabled)
                }
                if artifact.kind == .prURL {
                    Link(artifact.payloadRef, destination: URL(string: artifact.payloadRef) ?? URL(fileURLWithPath: "/"))
                        .font(.system(size: 11))
                }
            }
            Spacer()
            if artifact.boundary {
                if artifact.released {
                    Label("Done", systemImage: "checkmark").font(.system(size: 10.5)).foregroundStyle(Theme.success)
                } else {
                    Button("Approve & push") {
                        session.runner.releaseBoundaryAction(runId: run.id, artifactId: artifact.id)
                    }
                    .font(.system(size: 11))
                    .help("Boundary action — nothing leaves this machine until you click")
                }
            }
            if artifact.kind == .diff {
                Button("Open") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: artifact.payloadRef)
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 3)
    }

    private func artifactIcon(_ kind: ArtifactKind) -> String {
        switch kind {
        case .diff: return "plus.forwardslash.minus"
        case .branch: return "arrow.branch"
        case .file: return "doc"
        case .draftText: return "text.alignleft"
        case .report: return "doc.text"
        case .prURL: return "arrow.up.forward.square"
        case .externalWrite: return "paperplane"
        }
    }

    // MARK: - Failure (FR51)

    private var failureBlock: some View {
        gateBox(title: "FAILED", tint: Theme.danger) {
            Text(run?.failureReason ?? "Unknown failure")
                .font(.system(size: 12)).foregroundStyle(Theme.danger)
            HStack {
                Spacer()
                Button("Retry") { session.run(task) }
            }
        }
    }

    // MARK: - Run history (FR24/FR58)

    @ViewBuilder private var runHistory: some View {
        let runs = session.store.runs(for: task.id)
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("RUNS").font(.system(size: 10, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(Theme.faint)
                ForEach(runs) { r in
                    HStack(spacing: 8) {
                        Text(r.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                        Text(r.state.rawValue).font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(r.state == .succeeded ? Theme.success : Theme.muted)
                        Spacer()
                        if let path = r.transcriptPath {
                            Button("transcript") {
                                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                            }
                            .buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bits

    private func gateBox<Content: View>(title: String, tint: Color,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(tint)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Theme.field))
            .foregroundStyle(Theme.muted)
    }

    private func workingRow(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }
}
