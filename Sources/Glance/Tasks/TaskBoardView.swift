import SwiftUI

/// Task board app window (PRD V2 F1), light design (DS tokens).
/// Layout: floating tab pill over the active surface (spatial canvas / inbox
/// list / done history / activity feed) → footer. Selecting a task swaps in
/// the sidebar + detail pane (edit, plan gate, run stream, review gate).
struct TaskBoardView: View {
    @ObservedObject var session: TaskBoardSession
    @ObservedObject var store: TaskStore

    /// Clearance below the floating pill for the list-style tabs.
    static let pillInset: CGFloat = 60

    var body: some View {
        VStack(spacing: 0) {
            if session.showSettings {
                TaskSettingsView(session: session, onClose: { session.showSettings = false })
            } else if session.decomposeMode {
                decomposeView
            } else if let task = session.selectedTask, session.detailFullPage {
                // Expanded from the drawer: detail owns the whole page.
                // .id → fresh @State per task, else draft edits bleed across.
                TaskDetailView(session: session, task: task)
                    .id(task.id)
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .top) {
                        switch session.tab {
                        case .board:
                            CanvasView(session: session, store: store)
                        case .inbox:
                            list.padding(.top, Self.pillInset)
                        case .done:
                            DoneHistoryView(session: session, store: store)
                                .padding(.top, Self.pillInset)
                        case .activity:
                            activityView.padding(.top, Self.pillInset)
                        }
                        TabPill(session: session, store: store)
                            .padding(.top, DS.Space.sm)

                        // Detail drawer: slides in from the right over the tab.
                        if let task = session.selectedTask {
                            detailDrawer(task, width: geo.size.width * 0.5)
                        }
                    }
                    .animation(DS.spring, value: session.selectedTaskId)
                }
            }
            footer
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .background(DS.bg)
        .foregroundStyle(DS.textPrimary)
    }

    // MARK: - Detail drawer

    /// Right-side slide-over: scrim closes on click, panel hosts the same
    /// TaskDetailView (its header offers expand-to-full-page).
    private func detailDrawer(_ task: TaskItem, width: CGFloat) -> some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture { session.selectedTaskId = nil }
                .transition(.opacity)
            TaskDetailView(session: session, task: task)
                .id(task.id) // fresh @State per task — drafts must not bleed
                .frame(width: max(480, width))
                .frame(maxHeight: .infinity)
                .background(DS.bg)
                .overlay(alignment: .leading) {
                    Divider().overlay(DS.divider)
                }
                .shadow(color: .black.opacity(0.18), radius: 24, x: -6)
                .transition(.move(edge: .trailing))
                .onExitCommand { session.selectedTaskId = nil }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Inbox list (FR21–23; triage stays a list — canvas is for board)

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                let tasks = session.visibleTasks()
                // Bulk ops (V2.2): accept the whole inbox at once.
                if tasks.count > 1 {
                    bulkBar("Accept all \(tasks.count)", icon: "checkmark.circle") {
                        for t in tasks { session.store.acceptFromInbox(t.id) }
                    }
                }
                if tasks.isEmpty {
                    emptyState
                }
                ForEach(tasks) { task in
                    Button(action: { session.selectedTaskId = task.id }) {
                        TaskCardRow(session: session, task: task)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(DS.divider)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func bulkBar(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button(action: action) {
                Label(title, systemImage: icon).font(DS.Typo.label)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.accentText)
        }
        .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.xxs)
        .background(DS.surface)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.xs) {
            Image(systemName: emptyIcon)
                .font(.system(size: 28))
                .foregroundStyle(DS.textTertiary)
            Text(emptyTitle)
                .font(DS.Typo.headline)
                .foregroundStyle(DS.textSecondary)
            Text(emptyHint)
                .font(DS.Typo.caption)
                .foregroundStyle(DS.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Space.xl)
    }

    private var emptyIcon: String {
        switch session.tab {
        case .inbox: return "tray"
        case .done: return "checkmark.circle"
        default: return "checklist"
        }
    }

    private var emptyTitle: String {
        switch session.tab {
        case .board: return "No tasks yet"
        case .inbox: return "Inbox empty"
        case .done: return "Nothing finished yet"
        case .activity: return ""
        }
    }

    private var emptyHint: String {
        switch session.tab {
        case .board: return "Add one above, or paste a braindump via “From prompt”."
        case .inbox: return "AI-created tasks land here for your accept."
        case .done: return "Completed tasks show up here."
        case .activity: return ""
        }
    }

    // MARK: - Activity (FR58–59)

    private var activityView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let events = session.activityFeed()
                    if events.isEmpty {
                        VStack(spacing: DS.Space.xs) {
                            Image(systemName: "clock")
                                .font(.system(size: 28))
                                .foregroundStyle(DS.textTertiary)
                            Text("No activity yet")
                                .font(DS.Typo.headline)
                                .foregroundStyle(DS.textSecondary)
                            Text("Run a task and every gate decision lands here.")
                                .font(DS.Typo.caption)
                                .foregroundStyle(DS.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(DS.Space.xl)
                    }
                    ForEach(events) { e in
                        HStack(alignment: .top, spacing: DS.Space.xs) {
                            Image(systemName: e.icon)
                                .font(DS.Typo.caption)
                                .foregroundStyle(DS.textSecondary)
                                .frame(width: 16)
                            Text(e.text)
                                .font(DS.Typo.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(e.at.formatted(date: .abbreviated, time: .shortened))
                                .font(DS.Typo.mono)
                                .foregroundStyle(DS.textTertiary)
                        }
                        .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.xxs + 2)
                        Divider().overlay(DS.divider)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Spacer()
                Button(action: {
                    if let url = session.exportBoard() { NSWorkspace.shared.open(url) }
                }) {
                    Label("Export board + log as Markdown", systemImage: "square.and.arrow.up")
                        .font(DS.Typo.label)
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .foregroundStyle(DS.textPrimary)
            }
            .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.xs)
            .overlay(Divider().overlay(DS.divider), alignment: .top)
        }
    }

    // MARK: - Decompose flow (FR27)

    private var decomposeView: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                BackButton(label: "Back") { session.decomposeMode = false }
                Spacer()
                Text("Create tasks from a prompt").font(DS.Typo.headline)
                Spacer()
            }
            .padding(.top, DS.Space.md)

            if session.decomposePreview.isEmpty {
                TextEditor(text: $session.decomposeText)
                    .font(DS.Typo.body)
                    .scrollContentBackground(.hidden)
                    .dsField()
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        if session.decomposeText.isEmpty {
                            Text("Paste meeting notes, a Slack thread, an email, or just braindump…")
                                .font(DS.Typo.body).foregroundStyle(DS.textTertiary)
                                .padding(DS.Space.sm).allowsHitTesting(false)
                        }
                    }
                HStack {
                    Spacer()
                    Button(action: { session.runDecompose() }) {
                        HStack(spacing: DS.Space.xxs) {
                            if session.decomposeBusy { ProgressView().controlSize(.small) }
                            Text(session.decomposeBusy ? "Splitting…" : "Split into tasks")
                        }
                    }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .disabled(session.decomposeBusy || session.decomposeText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Text("Uncheck anything you don't want, then confirm:")
                    .font(DS.Typo.body).foregroundStyle(DS.textSecondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.xxs + 2) {
                        ForEach(Array(session.decomposePreview.enumerated()), id: \.offset) { i, t in
                            HStack(alignment: .top, spacing: DS.Space.xs) {
                                Toggle("", isOn: Binding(
                                    get: { session.decomposeKeep.contains(i) },
                                    set: { on in
                                        if on { session.decomposeKeep.insert(i) }
                                        else { session.decomposeKeep.remove(i) }
                                    }
                                )).labelsHidden().toggleStyle(.checkbox)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title).font(DS.Typo.body).fontWeight(.medium)
                                    if let d = t.description, !d.isEmpty {
                                        Text(d).font(DS.Typo.caption).foregroundStyle(DS.textSecondary).lineLimit(2)
                                    }
                                }
                            }
                            .padding(.vertical, DS.Space.xxs)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                HStack {
                    Button("Start over") { session.decomposePreview = [] }
                        .buttonStyle(.plain).foregroundStyle(DS.textSecondary).font(DS.Typo.label)
                    Spacer()
                    Button("Create \(session.decomposeKeep.count) task\(session.decomposeKeep.count == 1 ? "" : "s")") {
                        session.confirmDecompose()
                    }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .disabled(session.decomposeKeep.isEmpty)
                }
            }
        }
        .padding(.horizontal, DS.Space.md).padding(.bottom, DS.Space.sm)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DS.Space.xs) {
            let running = session.runner.activeRunIds.count
            Circle()
                .fill(running > 0 ? DS.accent : DS.textTertiary)
                .frame(width: 6, height: 6)
            Text(running > 0 ? "\(running) run\(running == 1 ? "" : "s") active" : "Idle")
                .font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
            if let status = session.pullStatus {
                Text("·  \(status)")
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if session.showSettings {
                // On the settings page the gear is pointless — offer jumps to
                // the ask overlay and back to the board instead.
                footerIcon("sparkle", help: "Open the ask overlay") { session.openAskHandler?() }
                footerIcon("checklist", help: "Back to the board") { session.showSettings = false }
            } else {
                footerIcon("gearshape", help: "Settings") { session.showSettings = true }
            }
        }
        .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.xs)
        .overlay(Divider().overlay(DS.divider), alignment: .top)
    }

    private func footerIcon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Hover { hovering in
            Button(action: action) {
                Image(systemName: symbol).font(DS.Typo.headline)
                    .foregroundStyle(hovering ? DS.textPrimary : DS.textSecondary)
                    .padding(DS.Space.xxs)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.small)
                        .fill(hovering ? DS.surfaceHover : .clear))
            }
            .buttonStyle(.plain)
        }
        .help(help)
    }

}

// MARK: - Hover helper

/// Reads hover state and hands it to the content builder — keeps hover
/// styling declarative without a @State per control.
struct Hover<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}

// MARK: - Back button (shared nav pattern)

/// Standardized back affordance: chevron + label, hover capsule.
struct BackButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Hover { hovering in
            Button(action: action) {
                Label(label, systemImage: "chevron.left")
                    .font(DS.Typo.label)
                    .foregroundStyle(hovering ? DS.textPrimary : DS.textSecondary)
                    .padding(.horizontal, DS.Space.xs).padding(.vertical, DS.Space.xxs)
                    .background(Capsule().fill(hovering ? DS.surfaceHover : .clear))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Card row (FR21/FR23)

private struct TaskCardRow: View {
    @ObservedObject var session: TaskBoardSession
    let task: TaskItem
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.xs + 2) {
            Image(systemName: task.source.icon)
                .font(DS.Typo.caption)
                .foregroundStyle(DS.textTertiary)
                .frame(width: 14)
                .help(task.source.displayName)

            priorityChip

            if let agent = Preferences.shared.agent(task.agentId) {
                Text(agent.icon)
                    .font(DS.Typo.caption)
                    .frame(width: 15)
                    .help(agent.name)
            }

            VStack(alignment: .leading, spacing: DS.Space.xxs - 1) {
                HStack(spacing: DS.Space.xxs + 2) {
                    if task.isPinned {
                        Image(systemName: "pin.fill").font(DS.Typo.overline).foregroundStyle(DS.accentText)
                    }
                    Text(task.title)
                        .font(DS.Typo.body).fontWeight(.medium)
                        .lineLimit(1)
                    if task.possibleDuplicateOf != nil {
                        dsBadge("dup?", tint: DS.warning, soft: DS.warningSoft)
                            .help("Looks like existing work — open to merge or dismiss")
                    }
                }
                HStack(spacing: DS.Space.xxs + 2) {
                    ForEach(task.labels.prefix(3), id: \.self) { label in
                        dsBadge(label, tint: DS.textSecondary, soft: DS.surface)
                    }
                    if !task.aiRationale.isEmpty {
                        Text(task.aiRationale)
                            .font(DS.Typo.caption).italic()
                            .foregroundStyle(DS.textTertiary).lineLimit(1)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: DS.Space.xxs - 1) {
                statusBadge
                Text(Self.addedLabel(task.createdAt))
                    .font(DS.Typo.mono)
                    .foregroundStyle(DS.textTertiary)
            }

            if hovering { hoverActions }
        }
        .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.xs)
        .background(hovering ? DS.surfaceHover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// "12m", "3h", "2d" — or the date once it's over a week old.
    static func addedLabel(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        switch s {
        case ..<3600: return "\(max(1, Int(s / 60)))m"
        case ..<86_400: return "\(Int(s / 3600))h"
        case ..<(7 * 86_400): return "\(Int(s / 86_400))d"
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    private var priorityChip: some View {
        dsBadge(task.aiPriority.rawValue, tint: priorityColor.tint, soft: priorityColor.soft)
    }

    private var priorityColor: (tint: Color, soft: Color) {
        switch task.aiPriority {
        case .p0: return (DS.danger, DS.dangerSoft)
        case .p1: return (DS.warning, DS.warningSoft)
        case .p2: return (DS.textSecondary, DS.surface)
        case .p3: return (DS.textTertiary, DS.surface)
        }
    }

    @ViewBuilder private var statusBadge: some View {
        let (text, tint, soft): (String, Color, Color) = {
            switch task.status {
            case .executing: return ("Running", DS.accentText, DS.accentSoft)
            case .planning: return ("Planning", DS.accentText, DS.accentSoft)
            case .awaitingPlanApproval: return ("Plan review", DS.warning, DS.warningSoft)
            case .awaitingReview: return ("Review", DS.warning, DS.warningSoft)
            case .failed: return ("Failed", DS.danger, DS.dangerSoft)
            case .queued: return ("Queued", DS.textSecondary, DS.surface)
            case .done: return ("Done", DS.success, DS.successSoft)
            case .inbox: return ("New", DS.accentText, DS.accentSoft)
            default: return ("", .clear, .clear)
            }
        }()
        if !text.isEmpty {
            dsBadge(text, tint: tint, soft: soft)
        }
    }

    @ViewBuilder private var hoverActions: some View {
        HStack(spacing: DS.Space.xs) {
            if task.status == .inbox {
                iconButton("checkmark.circle", "Accept onto board") {
                    session.store.acceptFromInbox(task.id)
                }
            }
            if task.isRunnable {
                iconButton("play.circle", "Run with AI") { session.run(task) }
            }
            iconButton(task.isPinned ? "pin.slash" : "pin", task.isPinned ? "Unpin" : "Pin to top") {
                session.togglePin(task)
            }
            iconButton("moon.zzz", "Snooze 24h") { session.snooze(task) }
            iconButton("archivebox", "Archive") { session.archive(task) }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Hover { hovering in
            Button(action: action) {
                Image(systemName: symbol).font(DS.Typo.label)
                    .foregroundStyle(hovering ? DS.textPrimary : DS.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .help(help)
    }
}
