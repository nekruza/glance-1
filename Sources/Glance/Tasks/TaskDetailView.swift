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
    @State private var editingTitle = false
    @State private var draftTitle = ""
    @State private var editingDescription = false
    @State private var draftDescription = ""
    @State private var editingPrompt = false
    @State private var draftPrompt = ""
    @State private var promptCopied = false
    @State private var editingPrep = false
    @State private var draftPrep = ""
    @State private var prepCopied = false
    @State private var editingHelper = false
    @State private var draftHelper = ""
    @State private var helperCopied = false
    /// Editable buffer for the draft-review gate (seeded once from helperDraft).
    @State private var draftReviewText = ""
    @State private var draftReviewSeeded = false
    @State private var newStepText = ""
    @State private var showDuePicker = false
    @State private var dueDraft = Date()
    @FocusState private var guidanceFocused: Bool
    @FocusState private var rejectFocused: Bool
    @FocusState private var stepFieldFocused: Bool
    @FocusState private var titleFocused: Bool

    private var run: TaskRun? { session.selectedRun }

    /// Calendar-sourced or "meeting"-labelled tasks get the prep-notes tools.
    private var isMeeting: Bool { task.helper == .prepNotes }

    /// Reference-quality reading width — keeps long lines scannable instead
    /// of stretching edge-to-edge in a wide drawer/full page.
    private static let contentWidth: CGFloat = 680

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        titleBlock
                        metaRow
                    }
                    if let dupId = task.possibleDuplicateOf {
                        duplicateBanner(dupId)
                    }
                    descriptionBlock
                    // One AI-output helper per task, routed by type — the
                    // card component (below) makes every type look the same
                    // shape even though the content differs.
                    switch task.helper {
                    case .prepNotes: prepBlock
                    case .handoffPrompt: promptBlock
                    default: helperBlock
                    }
                    stepsBlock

                    switch task.status {
                    case .awaitingPlanApproval: planGate
                    case .planning: workingRow("Planning…")
                    case .executing: executionStream
                    case .awaitingReview:
                        // A finished run parks here with the run at .succeeded
                        // (run gate); a draft awaiting send has no such run.
                        if hasRunReviewGate { reviewGate } else { draftReviewGate }
                    case .failed: failureBlock
                    default: EmptyView()
                    }

                    runHistory
                }
                .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
                .frame(maxWidth: Self.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .background(DS.surface.opacity(0.4))
        }
    }

    // MARK: - Chrome

    private var headerBar: some View {
        HStack {
            BackButton(label: session.detailFullPage ? "Board" : "Close") {
                session.selectedTaskId = nil
            }
            if !session.detailFullPage {
                // Drawer → promote to the full task page.
                Hover { hovering in
                    Button(action: { session.detailFullPage = true }) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(DS.Typo.label)
                            .foregroundStyle(hovering ? DS.textPrimary : DS.textSecondary)
                            .padding(DS.Space.xxs)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.small)
                                .fill(hovering ? DS.surfaceHover : .clear))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
                .help("Open as full page")
            }
            Spacer()
            // Manual completion — same celebration path as the canvas checkbox
            // (sound + status), minus the spatial confetti.
            if ![.done, .archived, .cancelled].contains(task.status) {
                Button(action: {
                    session.complete(task)
                    session.selectedTaskId = nil
                }) {
                    Label("Mark done", systemImage: "checkmark.circle")
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .foregroundStyle(DS.accentText)
                .help("Complete this task")
            }
            if isMeeting {
                Button(action: { session.generatePrepNotes(task) }) {
                    HStack(spacing: DS.Space.xxs) {
                        if session.prepBusyTaskIds.contains(task.id) {
                            ProgressView().controlSize(.small)
                            Text(session.prepPhase)
                        } else {
                            Label(task.prepNotes == nil ? "Prep notes" : "Regenerate notes",
                                  systemImage: "note.text.badge.plus")
                        }
                    }
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .disabled(session.prepBusyTaskIds.contains(task.id))
                .help("Fetches your last working day from Granola/Slack/Jira/GitHub "
                      + "and writes grounded prep notes into this task"
                      + (session.workContext.freshness().map { ". Context cached: \($0) ago" } ?? ""))
            }
            if task.helper == .handoffPrompt {
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
                .help(TaskHelper.handoffPrompt.help)
            }
            if ![.prepNotes, .handoffPrompt].contains(task.helper) {
                // Reply / draft / brief / approach — the type's helper action.
                Button(action: { session.generateHelperDraft(task) }) {
                    HStack(spacing: DS.Space.xxs) {
                        if session.draftBusyTaskIds.contains(task.id) {
                            ProgressView().controlSize(.small)
                            Text("Writing…")
                        } else {
                            Label(task.helperDraft == nil
                                  ? task.helper.buttonTitle : task.helper.regenerateTitle,
                                  systemImage: task.helper.icon)
                        }
                    }
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .disabled(session.draftBusyTaskIds.contains(task.id))
                .help(task.helper.help)
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
                .help("Stop the running agent")
            }
        }
        .padding(.horizontal, DS.Space.md).padding(.top, DS.Space.md).padding(.bottom, DS.Space.xs)
        .overlay(Divider().overlay(DS.divider), alignment: .bottom)
    }

    private var titleBlock: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: task.source.icon).font(DS.Typo.headline).foregroundStyle(DS.textTertiary)
            if editingTitle {
                TextField("", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(DS.Typo.title)
                    .focused($titleFocused)
                    .onSubmit(commitTitle)
                    .onChange(of: titleFocused) { _, focused in
                        // Commit on blur too, so clicking away saves the edit.
                        if !focused { commitTitle() }
                    }
            } else {
                Hover { hovering in
                    HStack(spacing: DS.Space.xs) {
                        Text(task.title).font(DS.Typo.title)
                        Image(systemName: "pencil")
                            .font(DS.Typo.label)
                            .foregroundStyle(DS.textTertiary)
                            .opacity(hovering ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .pointerCursor()
                .onTapGesture {
                    draftTitle = task.title
                    editingTitle = true
                    titleFocused = true
                }
                .help("Click to rename")
            }
        }
    }

    private func commitTitle() {
        guard editingTitle else { return }
        editingTitle = false
        let text = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != task.title else { return }
        var t = task
        t.title = text
        session.store.update(t)
    }

    /// Two rows: properties (priority/status/kind/due/estimate — what this
    /// task IS) on top, then tags + assignment (who/what runs it) below,
    /// visually distinct so the chip wall stops reading as one undifferentiated
    /// mass.
    private var metaRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            WrapLayout(spacing: DS.Space.xs) {
                statusBadge
                kindPicker
                duePicker
                if let e = task.estimate { chip("~\(e.rawValue)") }
            }
            WrapLayout(spacing: DS.Space.xs) {
                ForEach(task.labels, id: \.self) { tagChip($0) }
                // Repo only matters for code tasks — everything else runs in
                // a scratch workspace and needs no repo.
                if task.taskKind == .code {
                    repoPicker
                }
                agentPicker
                modelPicker
            }
        }
    }

    /// Priority dot + status text as one pill — the two facts read together
    /// ("how urgent, what state") instead of as two separate chips.
    private var statusBadge: some View {
        HStack(spacing: DS.Space.xxs) {
            Circle().fill(DS.priorityDot(task.aiPriority)).frame(width: 6, height: 6)
            Text(task.aiPriority.rawValue)
            Text("·").foregroundStyle(DS.textTertiary)
            Text(task.status.display)
        }
        .font(DS.Typo.caption)
        .fixedSize()
        .foregroundStyle(DS.textSecondary)
        .padding(.horizontal, DS.Space.xs).padding(.vertical, 3)
        .background(Capsule().fill(DS.surface))
        .overlay(Capsule().strokeBorder(DS.border, lineWidth: 1))
    }

    /// Tag chips (user labels) get a quieter, outline-only treatment —
    /// visually distinct from the solid property/picker chips above.
    private func tagChip(_ text: String) -> some View {
        Text(text)
            .font(DS.Typo.caption)
            .fixedSize()
            .foregroundStyle(DS.textTertiary)
            .padding(.horizontal, DS.Space.xxs + 2).padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(DS.divider, lineWidth: 1))
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

    /// Due date, finally editable (the model field predates the UI).
    private var duePicker: some View {
        Button(action: {
            dueDraft = task.dueAt ?? Calendar.current.startOfDay(for: Date())
            showDuePicker = true
        }) {
            pickerChip(nil, isSet: task.dueAt != nil) {
                if let due = task.dueAt {
                    let d = TaskCanvasCard.dueLabel(due)
                    Label(d.text, systemImage: "clock").foregroundStyle(d.color)
                } else {
                    Label("due…", systemImage: "clock")
                }
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDuePicker, arrowEdge: .bottom) {
            VStack(spacing: DS.Space.sm) {
                DatePicker("", selection: $dueDraft, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                HStack {
                    if task.dueAt != nil {
                        Button("Clear") {
                            var t = task
                            t.dueAt = nil
                            session.store.update(t)
                            showDuePicker = false
                        }
                        .buttonStyle(DSSecondaryButtonStyle())
                    }
                    Spacer()
                    Button("Set due date") {
                        var t = task
                        t.dueAt = dueDraft
                        session.store.update(t)
                        showDuePicker = false
                    }
                    .buttonStyle(DSPrimaryButtonStyle())
                }
            }
            .padding(DS.Space.sm)
            .frame(width: 260)
        }
        .help("Due date — shows on the Todo card")
    }

    // MARK: - Steps (checklist → progress bar on the canvas card)

    private var stepsBlock: some View {
        sectionCard(icon: "checklist", title: "Steps", accent: false, aiFilled: false,
                    trailingText: task.stepList.isEmpty ? nil : "\(task.stepsDone)/\(task.stepList.count)") {
            ForEach(task.stepList) { step in
                stepRow(step)
            }
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "plus")
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.textTertiary)
                TextField("", text: $newStepText,
                          prompt: Text("Add a step…").foregroundColor(DS.textTertiary))
                    .textFieldStyle(.plain)
                    .font(DS.Typo.body)
                    .focused($stepFieldFocused)
                    .onSubmit(addStep)
            }
            .padding(.vertical, DS.Space.xxs)
        }
    }

    private func stepRow(_ step: TaskStep) -> some View {
        Hover { hovering in
            HStack(spacing: DS.Space.xs) {
                Button(action: { toggleStep(step) }) {
                    Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                        .font(DS.Typo.headline)
                        .foregroundStyle(step.done ? DS.accentText : DS.textTertiary)
                }
                .buttonStyle(.plain)
                Text(step.text)
                    .font(DS.Typo.body)
                    .foregroundStyle(step.done ? DS.textTertiary : DS.textPrimary)
                    .strikethrough(step.done, color: DS.textTertiary)
                Spacer()
                if hovering {
                    Button(action: { removeStep(step) }) {
                        Image(systemName: "xmark")
                            .font(DS.Typo.caption)
                            .foregroundStyle(DS.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete step")
                }
            }
            .padding(.horizontal, DS.Space.xxs).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: DS.Radius.small)
                .fill(hovering ? DS.surfaceHover : .clear))
        }
    }

    private func addStep() {
        let text = newStepText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var t = task
        t.steps = t.stepList + [TaskStep(text: text)]
        session.store.update(t)
        newStepText = ""
        stepFieldFocused = true
    }

    private func toggleStep(_ step: TaskStep) {
        var t = task
        var steps = t.stepList
        guard let idx = steps.firstIndex(where: { $0.id == step.id }) else { return }
        steps[idx].done.toggle()
        t.steps = steps
        session.store.update(t)
    }

    private func removeStep(_ step: TaskStep) {
        var t = task
        t.steps = t.stepList.filter { $0.id != step.id }
        session.store.update(t)
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

    /// Reference material — what the task IS, not what to do about it.
    /// Neutral card so it recedes behind the AI-output card below it.
    private var descriptionBlock: some View {
        sectionCard(icon: task.source.icon, title: "Description", accent: false,
                    aiFilled: task.aiFilledFields.contains("description"),
                    editAction: { commitOrBeginEdit($editingDescription, $draftDescription, task.descriptionMD) {
                        var t = task; t.descriptionMD = draftDescription; session.store.update(t)
                    } },
                    editing: editingDescription) {
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

    // MARK: - Meeting prep notes

    /// AI-written prep notes for a meeting task. Hidden until generated
    /// (header button); then editable, copyable, regenerable.
    @ViewBuilder private var prepBlock: some View {
        if let notes = task.prepNotes {
            sectionCard(icon: TaskHelper.prepNotes.icon, title: TaskHelper.prepNotes.sectionTitle,
                        accent: true, aiFilled: true,
                        copyAction: { copy(notes, flag: $prepCopied) }, copied: prepCopied,
                        editAction: { commitOrBeginEdit($editingPrep, $draftPrep, notes) {
                            var t = task; t.prepNotes = draftPrep; session.store.update(t)
                        } },
                        editing: editingPrep) {
                if editingPrep {
                    TextEditor(text: $draftPrep)
                        .font(DS.Typo.body)
                        .scrollContentBackground(.hidden)
                        .frame(height: 180)
                        .dsField()
                } else {
                    MarkdownText(text: notes, palette: .light)
                        .font(DS.Typo.body)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Helper draft (reply / draft / brief / approach)

    /// Type-appropriate helper output. Hidden until generated (header
    /// button); then editable, copyable, regenerable. Same card shape as
    /// prep notes and the handoff prompt — only the icon/title vary by type.
    @ViewBuilder private var helperBlock: some View {
        if let draft = task.helperDraft {
            sectionCard(icon: task.helper.icon, title: task.helper.sectionTitle,
                        accent: true, aiFilled: true,
                        copyAction: { copy(draft, flag: $helperCopied) }, copied: helperCopied,
                        editAction: { commitOrBeginEdit($editingHelper, $draftHelper, draft) {
                            var t = task; t.helperDraft = draftHelper; session.store.update(t)
                        } },
                        editing: editingHelper) {
                if editingHelper {
                    TextEditor(text: $draftHelper)
                        .font(DS.Typo.body)
                        .scrollContentBackground(.hidden)
                        .frame(height: 180)
                        .dsField()
                } else {
                    MarkdownText(text: draft, palette: .light)
                        .font(DS.Typo.body)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Handoff prompt (code tasks)

    /// AI-written prompt for pasting into an external assistant. Hidden until
    /// generated (header button); then editable, copyable, regenerable.
    @ViewBuilder private var promptBlock: some View {
        if let prompt = task.handoffPrompt {
            sectionCard(icon: TaskHelper.handoffPrompt.icon, title: TaskHelper.handoffPrompt.sectionTitle,
                        accent: true, aiFilled: true,
                        copyAction: { copy(prompt, flag: $promptCopied) }, copied: promptCopied,
                        editAction: { commitOrBeginEdit($editingPrompt, $draftPrompt, prompt) {
                            var t = task; t.handoffPrompt = draftPrompt; session.store.update(t)
                        } },
                        editing: editingPrompt) {
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
                }
            }
        }
    }

    // MARK: - Section card (shared shape for description + every AI output)

    /// One visual pattern for "a block of text about this task": neutral for
    /// reference material (description), accent-tinted with a left-weighted
    /// icon for AI-generated actionable output (prep/prompt/reply/draft/
    /// brief/approach) — so every task type's helper looks like the same
    /// kind of thing even though the content differs.
    private func sectionCard<Content: View>(
        icon: String, title: String, accent: Bool, aiFilled: Bool,
        trailingText: String? = nil,
        copyAction: (() -> Void)? = nil, copied: Bool = false,
        editAction: (() -> Void)? = nil, editing: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xxs) {
                Image(systemName: icon)
                    .font(DS.Typo.caption)
                    .foregroundStyle(accent ? DS.accentText : DS.textTertiary)
                Text(title.uppercased())
                    .font(DS.Typo.overline).tracking(0.8)
                    .foregroundStyle(accent ? DS.accentText : DS.textTertiary)
                if aiFilled {
                    Image(systemName: "sparkle").font(DS.Typo.overline).foregroundStyle(DS.accentText)
                        .help("AI-written — edit freely, your version wins")
                }
                if let trailingText {
                    Text(trailingText).font(DS.Typo.overline).foregroundStyle(DS.textTertiary)
                }
                Spacer()
                if let copyAction {
                    Button(copied ? "Copied" : "Copy", action: copyAction)
                        .buttonStyle(.plain).font(DS.Typo.label)
                        .foregroundStyle(copied ? DS.success : DS.accentText)
                }
                if let editAction {
                    Button(editing ? "Save" : "Edit", action: editAction)
                        .buttonStyle(.plain).font(DS.Typo.label).foregroundStyle(DS.accentText)
                }
            }
            content()
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium)
            .fill(accent ? DS.accentSoft.opacity(0.5) : DS.bg))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium)
            .strokeBorder(accent ? DS.accent.opacity(0.3) : DS.border, lineWidth: 1))
        .compositingGroup() // fill+stroke in one pass — avoids a hairline seam
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium))
    }

    private func copy(_ text: String, flag: Binding<Bool>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flag.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { flag.wrappedValue = false }
    }

    /// Edit/Save toggle shared by every AI-output card: entering edit mode
    /// seeds the draft from current text, saving calls `commit`.
    private func commitOrBeginEdit(_ editing: Binding<Bool>, _ draft: Binding<String>,
                                   _ current: String, commit: () -> Void) {
        if editing.wrappedValue {
            commit()
        } else {
            draft.wrappedValue = current
        }
        editing.wrappedValue.toggle()
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

    // MARK: - Draft-review gate (outbound send / approve / reject)

    /// True when a finished run is parked at the review gate — distinguishes it
    /// from a draft gate (which has a helper draft and no such run). A task
    /// with neither (stale run state) also lands here, never on an empty
    /// draft gate with send buttons.
    private var hasRunReviewGate: Bool {
        run?.state == .succeeded || task.helperDraft == nil
    }

    /// Title varies with the concrete target so the button says what it does.
    private var sendButtonTitle: String {
        switch task.outboundTarget {
        case .slackReply: return "Approve & send reply"
        case .jiraComment: return "Approve & post comment"
        case .none: return "Approve & send"
        }
    }

    /// The draft awaiting the user's call: editable text, then Approve & send
    /// (outbound, when a target exists), plain Approve (accept as done), or
    /// Reject (back to Ready). Draft-gate tasks always come from Slack/Jira, so
    /// the send button shows; it's disabled with a hint when the source link is
    /// missing (per the I/O matrix).
    private var draftReviewGate: some View {
        gateBox(title: "DRAFT — YOUR APPROVAL NEEDED", tint: DS.warning, soft: DS.warningSoft) {
            TextEditor(text: $draftReviewText)
                .font(DS.Typo.body)
                .scrollContentBackground(.hidden)
                .frame(height: 160)
                .dsField()
                .onAppear {
                    if !draftReviewSeeded {
                        draftReviewText = task.helperDraft ?? ""
                        draftReviewSeeded = true
                    }
                }
            if task.outboundTarget == nil {
                Text("No \(task.source == .slack ? "Slack thread" : "Jira issue") link on this task — sending is unavailable, but you can still approve it.")
                    .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
            }
            if let err = session.sendError[task.id] {
                Text(err).font(DS.Typo.caption).foregroundStyle(DS.danger)
            }
            // Once a send is in flight the message may already be out —
            // freeze every decision button, not just the send one.
            let sending = session.sendBusyTaskIds.contains(task.id)
            HStack {
                Button("Reject") {
                    session.rejectDraft(task)
                    session.selectedTaskId = nil
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .foregroundStyle(DS.danger)
                .disabled(sending)
                Spacer()
                Button("Approve") {
                    persistDraftEdit()
                    session.approveDraft(task)
                    session.selectedTaskId = nil
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .help("Accept this draft as done without sending")
                .disabled(sending)
                Button(action: { session.approveSend(task, editedDraft: draftReviewText) }) {
                    HStack(spacing: DS.Space.xxs) {
                        if session.sendBusyTaskIds.contains(task.id) {
                            ProgressView().controlSize(.small)
                            Text("Sending…")
                        } else {
                            Label(sendButtonTitle, systemImage: "paperplane.fill")
                        }
                    }
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(task.outboundTarget == nil
                          || session.sendBusyTaskIds.contains(task.id)
                          || draftReviewText.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(task.outboundTarget == nil
                      ? "No thread/issue link — can't send"
                      : "Post to the exact Slack thread / Jira issue this came from")
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Persist an in-gate edit to helperDraft (plain Approve path — send
    /// persists its own edit inside approveSend).
    private func persistDraftEdit() {
        guard draftReviewSeeded, var t = session.store.task(task.id),
              t.helperDraft != draftReviewText else { return }
        t.helperDraft = draftReviewText
        session.store.update(t)
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
            .fixedSize()
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
                .fixedSize()
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
