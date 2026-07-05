import SwiftUI

/// Task detail (FR24) + the two gates: plan approval (FR44.2) and review
/// (FR52–53). Shown inside the Tasks window when a task is selected.
struct TaskDetailView: View {
    @ObservedObject var session: TaskBoardSession
    // Observed so the repo picker rebuilds when repos are added in Settings —
    // reading Preferences.shared statically left the menu stuck on empty.
    @ObservedObject private var prefs = Preferences.shared
    let task: TaskItem

    @State private var guidance = ""
    @State private var rejectReason = ""
    @State private var editingDescription = false
    @State private var draftDescription = ""
    @State private var editingPrompt = false
    @State private var draftPrompt = ""
    @State private var promptCopied = false
    @FocusState private var guidanceFocused: Bool
    @FocusState private var rejectFocused: Bool

    private var run: TaskRun? { session.selectedRun }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    titleBlock
                    metaRow
                    if let dupId = task.possibleDuplicateOf {
                        duplicateBanner(dupId)
                    }
                    descriptionBlock
                    if task.taskKind == .code { promptBlock }

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
                .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Chrome

    private var headerBar: some View {
        HStack {
            BackButton(label: "Board") { session.selectedTaskId = nil }
            Spacer()
            if task.taskKind == .code {
                Button(action: { session.generateHandoffPrompt(task) }) {
                    HStack(spacing: DS.Space.xxs) {
                        if session.promptBusyTaskIds.contains(task.id) {
                            ProgressView().controlSize(.small)
                            Text("Writing prompt…")
                        } else {
                            Label(task.handoffPrompt == nil ? "Create prompt" : "Regenerate prompt",
                                  systemImage: "wand.and.sparkles")
                        }
                    }
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .disabled(session.promptBusyTaskIds.contains(task.id))
                .help("AI writes a prompt you can paste into another assistant")
            }
            if task.isRunnable {
                Button(action: { session.run(task) }) {
                    Label("Run with AI", systemImage: "play.fill")
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(task.taskKind == .code && (task.workspacePath ?? "").isEmpty)
                .help(task.taskKind == .code && (task.workspacePath ?? "").isEmpty
                      ? "Set a repo first (code task)" : "Plan → approve → execute")
            }
            if task.status == .executing || task.status == .planning {
                Button(action: { if let r = run { session.runner.cancelRun(runId: r.id) } }) {
                    Label("Cancel", systemImage: "stop.fill")
                        .foregroundStyle(DS.danger)
                }
                .buttonStyle(DSSecondaryButtonStyle())
            }
        }
        .padding(.horizontal, DS.Space.md).padding(.top, DS.Space.md).padding(.bottom, DS.Space.xs)
        .overlay(Divider().overlay(DS.divider), alignment: .bottom)
    }

    private var titleBlock: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: task.source.icon).font(DS.Typo.headline).foregroundStyle(DS.textTertiary)
            Text(task.title).font(DS.Typo.title)
        }
    }

    private var metaRow: some View {
        HStack(spacing: DS.Space.xs) {
            chip(task.aiPriority.rawValue)
            chip(task.status.display)
            kindPicker
            if let e = task.estimate { chip("~\(e.rawValue)") }
            ForEach(task.labels, id: \.self) { chip($0) }
            Spacer()
            // Repo only matters for code tasks — everything else runs in a
            // scratch workspace and needs no repo.
            if task.taskKind == .code {
                repoPicker
            }
            agentPicker
            modelPicker
        }
    }

    /// Skill profile executing this task (AI-routed; user override wins).
    private var agentPicker: some View {
        let current = prefs.agent(task.agentId)
        return Menu {
            Button("None (generic)") {
                var t = task
                t.agentId = nil
                session.store.update(t)
            }
            Divider()
            ForEach(prefs.agents) { agent in
                Button {
                    var t = task
                    t.agentId = agent.id
                    session.store.update(t)
                } label: {
                    Text("\(agent.icon) \(agent.name) — \(agent.skills)")
                }
            }
        } label: {
            pickerChip(current == nil ? "🤖 agent" : "\(current!.icon) \(current!.name)",
                       isSet: current != nil)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which skill profile runs this task")
    }

    /// OQ-V2-3: per-task model for agent runs. Default = CLI's own default.
    /// Labels carry the resolved model names once the catalog has probed.
    private var modelPicker: some View {
        Menu {
            Button("auto — agent's choice, else opus") {
                var t = task
                t.runModel = nil
                session.store.update(t)
            }
            ForEach(["haiku", "sonnet", "opus"], id: \.self) { m in
                Button(menuLabel(m)) {
                    var t = task
                    t.runModel = m
                    session.store.update(t)
                }
            }
        } label: {
            pickerChip(nil, isSet: task.runModel != nil) {
                Label(task.runModel ?? "auto", systemImage: "cpu")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Model for AI runs on this task (plan + execution)")
    }

    private func menuLabel(_ alias: String) -> String {
        if let resolved = ModelCatalog.shared.displayName(for: alias) {
            return "\(alias) — \(resolved)"
        }
        return alias
    }

    /// Kind is editable so a misclassified task can be flipped to `code`
    /// (which reveals the repo picker) or away from it.
    private var kindPicker: some View {
        Menu {
            ForEach(TaskKind.allCases, id: \.self) { kind in
                Button(kind.rawValue) {
                    var t = task
                    t.taskKind = kind
                    if kind != .code { t.workspacePath = nil }
                    session.store.update(t)
                }
            }
        } label: {
            chip(task.taskKind.rawValue)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Task kind — code tasks run in a repo worktree")
    }

    private var repoPicker: some View {
        Menu {
            ForEach(prefs.repos) { repo in
                Button(repo.name) {
                    var t = task
                    t.workspacePath = repo.path
                    session.store.update(t)
                }
            }
            if prefs.repos.isEmpty {
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
            let name = prefs.repos.first { $0.path == task.workspacePath }?.name
            pickerChip(nil, isSet: name != nil) {
                Label(name ?? "repo…", systemImage: "folder")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// FR33: never auto-merged — user decides.
    private func duplicateBanner(_ dupId: UUID) -> some View {
        let other = session.store.task(dupId)
        return gateBox(title: "POSSIBLE DUPLICATE", tint: DS.warning, soft: DS.warningSoft) {
            Text("Looks like: “\(other?.title ?? "(deleted task)")”")
                .font(DS.Typo.body)
            HStack {
                Button("Not a duplicate") {
                    session.store.dismissDuplicateFlag(task.id)
                }
                .buttonStyle(DSSecondaryButtonStyle())
                Spacer()
                if other != nil {
                    Button("Merge into that task") {
                        session.store.mergeDuplicate(task.id, into: dupId)
                        session.selectedTaskId = dupId
                    }
                    .buttonStyle(DSSecondaryButtonStyle())
                }
            }
        }
    }

    private var descriptionBlock: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs + 2) {
            HStack {
                overline("Description")
                if task.aiFilledFields.contains("description") {
                    Image(systemName: "sparkle").font(DS.Typo.overline).foregroundStyle(DS.accentText)
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
                .buttonStyle(.plain).font(DS.Typo.label).foregroundStyle(DS.accentText)
            }
            if editingDescription {
                TextEditor(text: $draftDescription)
                    .font(DS.Typo.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 100)
                    .dsField()
            } else if task.descriptionMD.isEmpty {
                Text("No description — Edit to add one")
                    .font(DS.Typo.body).foregroundStyle(DS.textTertiary)
            } else {
                MarkdownText(text: task.descriptionMD, palette: .light).font(DS.Typo.body)
            }
        }
    }

    // MARK: - Handoff prompt (code tasks)

    /// AI-written prompt for pasting into an external assistant. Hidden until
    /// generated (header button); then editable, copyable, regenerable.
    @ViewBuilder private var promptBlock: some View {
        if let prompt = task.handoffPrompt {
            VStack(alignment: .leading, spacing: DS.Space.xxs + 2) {
                HStack {
                    overline("Prompt for your AI")
                    Image(systemName: "sparkle").font(DS.Typo.overline).foregroundStyle(DS.accentText)
                        .help("AI-written — edit freely, your version wins")
                    Spacer()
                    Button(promptCopied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(task.handoffPrompt ?? "", forType: .string)
                        promptCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { promptCopied = false }
                    }
                    .buttonStyle(.plain).font(DS.Typo.label)
                    .foregroundStyle(promptCopied ? DS.success : DS.accentText)
                    Button(editingPrompt ? "Save" : "Edit") {
                        if editingPrompt {
                            var t = task
                            t.handoffPrompt = draftPrompt
                            session.store.update(t)
                        } else {
                            draftPrompt = prompt
                        }
                        editingPrompt.toggle()
                    }
                    .buttonStyle(.plain).font(DS.Typo.label).foregroundStyle(DS.accentText)
                }
                if editingPrompt {
                    TextEditor(text: $draftPrompt)
                        .font(DS.Typo.mono)
                        .scrollContentBackground(.hidden)
                        .frame(height: 180)
                        .dsField()
                } else {
                    MarkdownText(text: prompt, palette: .light)
                        .font(DS.Typo.body)
                        .textSelection(.enabled)
                        .padding(DS.Space.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.codeBg))
                }
            }
        }
    }

    // MARK: - Plan gate (FR44.2)

    private var planGate: some View {
        gateBox(title: "PLAN — YOUR APPROVAL NEEDED", tint: DS.warning, soft: DS.warningSoft) {
            if let plan = run?.plan {
                MarkdownText(text: plan, palette: .light).font(DS.Typo.body)
            }
            TextField("", text: $guidance,
                      prompt: Text("Optional guidance to append…").foregroundColor(DS.textTertiary))
                .textFieldStyle(.plain)
                .font(DS.Typo.body)
                .focused($guidanceFocused)
                .dsField(focused: guidanceFocused)
            HStack {
                Button("Reject") {
                    if let r = run { session.runner.rejectPlan(runId: r.id, reason: guidance) }
                    guidance = ""
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .foregroundStyle(DS.danger)
                Spacer()
                Button("Approve & execute") {
                    if let r = run {
                        session.runner.approvePlan(runId: r.id,
                                                   guidance: guidance.isEmpty ? nil : guidance)
                    }
                    guidance = ""
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Execution stream (FR44.3)

    private var executionStream: some View {
        gateBox(title: "RUNNING", tint: DS.accentText, soft: DS.accentSoft) {
            workingRow("Agent working in \(run?.branchName ?? "scratch")…")
            if let tail = run?.progressTail, !tail.isEmpty {
                Text(tail)
                    .font(DS.Typo.mono)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Space.xs)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.codeBg))
            }
        }
    }

    // MARK: - Review gate (FR52–53)

    private var reviewGate: some View {
        gateBox(title: "REVIEW — RESULT READY", tint: DS.warning, soft: DS.warningSoft) {
            if let run {
                ForEach(run.artifacts) { artifact in
                    artifactRow(artifact, run: run)
                }
            }
            TextField("", text: $rejectReason,
                      prompt: Text("Rejection reason / retry guidance…").foregroundColor(DS.textTertiary))
                .textFieldStyle(.plain)
                .font(DS.Typo.body)
                .focused($rejectFocused)
                .dsField(focused: rejectFocused)
            HStack {
                Button("Reject") {
                    if let r = run { session.runner.rejectReview(runId: r.id, reason: rejectReason) }
                    rejectReason = ""
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .foregroundStyle(DS.danger)
                Spacer()
                Button("Approve") {
                    if let r = run { session.runner.approveReview(runId: r.id, releaseBoundary: false) }
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .help("Accept the work. Boundary actions (push/PR) stay individually gated below.")
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func artifactRow(_ artifact: RunArtifact, run: TaskRun) -> some View {
        HStack(alignment: .top, spacing: DS.Space.xs) {
            Image(systemName: artifactIcon(artifact.kind))
                .font(DS.Typo.caption)
                .foregroundStyle(artifact.boundary ? DS.warning : DS.textSecondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.summary).font(DS.Typo.body)
                if artifact.kind == .draftText {
                    Text(artifact.payloadRef)
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                }
                if artifact.kind == .prURL {
                    if let url = URL(string: artifact.payloadRef) {
                        Link(artifact.payloadRef, destination: url)
                            .font(DS.Typo.caption)
                            .foregroundStyle(DS.accentText)
                    } else {
                        Text(artifact.payloadRef)
                            .font(DS.Typo.mono)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer()
            if artifact.boundary {
                if artifact.released {
                    Label("Done", systemImage: "checkmark").font(DS.Typo.caption).foregroundStyle(DS.success)
                } else {
                    Button("Approve & push") {
                        session.runner.releaseBoundaryAction(runId: run.id, artifactId: artifact.id)
                    }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .foregroundStyle(DS.warning)
                    .help("Boundary action — nothing leaves this machine until you click")
                }
            }
            if artifact.kind == .diff {
                Button("Open") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: artifact.payloadRef)
                }
                .buttonStyle(.plain).font(DS.Typo.label).foregroundStyle(DS.accentText)
            }
        }
        .padding(.vertical, DS.Space.xxs - 1)
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
        gateBox(title: "FAILED", tint: DS.danger, soft: DS.dangerSoft) {
            Text(run?.failureReason ?? "Unknown failure")
                .font(DS.Typo.body).foregroundStyle(DS.danger)
            HStack {
                Spacer()
                Button("Retry") { session.run(task) }
                    .buttonStyle(DSPrimaryButtonStyle())
            }
        }
    }

    // MARK: - Run history (FR24/FR58)

    @ViewBuilder private var runHistory: some View {
        let runs = session.store.runs(for: task.id)
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xxs + 2) {
                overline("Runs")
                ForEach(runs) { r in
                    Hover { hovering in
                        HStack(spacing: DS.Space.xs) {
                            Text(r.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
                            Text(r.state.rawValue).font(DS.Typo.mono)
                                .foregroundStyle(r.state == .succeeded ? DS.success : DS.textSecondary)
                            Spacer()
                            if let path = r.transcriptPath {
                                Button("transcript") {
                                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                                }
                                .buttonStyle(.plain).font(DS.Typo.caption).foregroundStyle(DS.accentText)
                            }
                        }
                        .padding(.horizontal, DS.Space.xxs).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.small)
                            .fill(hovering ? DS.surfaceHover : .clear))
                    }
                }
            }
        }
    }

    // MARK: - Bits

    private func overline(_ text: String) -> some View {
        Text(text.uppercased())
            .font(DS.Typo.overline).tracking(0.8)
            .foregroundStyle(DS.textTertiary)
    }

    private func gateBox<Content: View>(title: String, tint: Color, soft: Color,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs + 2) {
            Text(title).font(DS.Typo.overline).tracking(0.8).foregroundStyle(tint)
            content()
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(soft))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium)
            .strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(DS.Typo.caption)
            .padding(.horizontal, DS.Space.xxs + 2).padding(.vertical, 2)
            .background(Capsule().fill(DS.surface))
            .foregroundStyle(DS.textSecondary)
    }

    /// Picker chip: like `chip` but signals unset state (lighter text +
    /// dashed border) so it reads as actionable, and shows hover feedback.
    private func pickerChip(_ text: String?, isSet: Bool) -> some View {
        pickerChip(text, isSet: isSet) { Text(text ?? "") }
    }

    private func pickerChip<L: View>(_ text: String?, isSet: Bool,
                                     @ViewBuilder label: () -> L) -> some View {
        let content = label()
        return Hover { hovering in
            content
                .font(DS.Typo.caption)
                .foregroundStyle(isSet ? DS.textSecondary : DS.textTertiary)
                .padding(.horizontal, DS.Space.xxs + 2).padding(.vertical, 2)
                .background(Capsule().fill(hovering ? DS.surfaceHover : DS.surface))
                .overlay(
                    Capsule().strokeBorder(DS.border,
                                           style: StrokeStyle(lineWidth: 1, dash: isSet ? [] : [3, 2]))
                )
        }
    }

    private func workingRow(_ label: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            ProgressView().controlSize(.small)
            Text(label).font(DS.Typo.body).foregroundStyle(DS.textSecondary)
        }
    }
}
