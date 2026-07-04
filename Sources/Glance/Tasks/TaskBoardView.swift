import SwiftUI

/// Task board overlay (PRD V2 F1). Same dark-glass system as the ask overlay.
/// Layout: header (tabs + search) → quick-add → task list → footer.
/// Selecting a task slides in the detail pane (edit, plan gate, run stream,
/// review gate).
struct TaskBoardView: View {
    @ObservedObject var session: TaskBoardSession
    @ObservedObject var store: TaskStore
    @ObservedObject private var prefs = Preferences.shared
    @FocusState private var quickAddFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if session.showSettings {
                TaskSettingsView(onClose: { session.showSettings = false })
            } else if session.decomposeMode {
                decomposeView
            } else if let task = session.selectedTask {
                TaskDetailView(session: session, task: task)
            } else if session.tab == .activity {
                header
                activityView
            } else {
                header
                quickAddRow
                list
            }
            footer
        }
        .frame(width: 700, height: 640)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.glassTint.opacity(prefs.overlayOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.glassBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(alignment: .topTrailing) { closeButton.padding(5) }
        .foregroundStyle(Theme.fg)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
            tabBar

            Spacer()

            // Manual Composio pulls (read-only → Inbox).
            if let src = session.pullingSource {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Pulling \(src.rawValue)…").font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                }
            } else {
                Menu {
                    Button("Pull from all") { session.pullAll() }
                    Divider()
                    ForEach(ComposioIngest.Source.allCases, id: \.self) { src in
                        Button("Pull from \(src.rawValue)") { session.pull(src) }
                    }
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Fetch new work into the Inbox (read-only)")
            }

            if session.tab == .board {
                Menu {
                    ForEach(TaskBoardSession.SortMode.allCases, id: \.self) { mode in
                        Button(action: { session.sortMode = mode }) {
                            HStack {
                                Text(mode.rawValue)
                                if session.sortMode == mode { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12))
                        .foregroundStyle(session.sortMode == .aiRank ? Theme.muted : Theme.accent)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort: \(session.sortMode.rawValue)")
            }

            if session.isPrioritizing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Prioritizing…").font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                }
            } else {
                Button(action: { session.schedulePrioritize(force: true) }) {
                    Image(systemName: "wand.and.stars").font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help("Re-prioritize with AI")
            }

            TextField("", text: $session.searchText,
                      prompt: Text("Search").foregroundColor(Theme.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 110)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
    }

    /// Custom segmented control: the system Picker can't render count badges.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(TaskBoardSession.Tab.allCases, id: \.self) { tab in
                let selected = session.tab == tab
                Button(action: { session.tab = tab }) {
                    HStack(spacing: 5) {
                        Text(tab.rawValue)
                            .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Theme.fg : Theme.muted)
                        if let n = tabCount(tab), n > 0 {
                            Text(n > 99 ? "99+" : "\(n)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.black.opacity(0.8))
                                .frame(minWidth: 13, minHeight: 13)
                                .background(Circle().fill(tab == .inbox ? Theme.accent : Theme.muted))
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selected ? Color.white.opacity(0.12) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
    }

    private func tabCount(_ tab: TaskBoardSession.Tab) -> Int? {
        switch tab {
        case .inbox: return store.inboxTasks().count
        case .board: return store.boardTasks().count
        case .done: return store.doneTasks().count
        case .activity: return nil
        }
    }

    // MARK: - Quick add (FR26)

    private var quickAddRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.faint)
            TextField("", text: $session.quickAdd,
                      prompt: Text("Add a task…").foregroundColor(Theme.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .tint(Theme.accent)
                .focused($quickAddFocused)
                .onSubmit { session.submitQuickAdd() }
            Button(action: { session.startDecompose() }) {
                Label("From prompt", systemImage: "text.badge.plus")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .help("Paste a braindump — AI splits it into tasks you confirm")
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
        .overlay(Divider().overlay(Theme.glassBorder), alignment: .bottom)
    }

    // MARK: - List (FR21–23)

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                let tasks = session.visibleTasks()
                // Bulk ops (V2.2): accept the whole inbox / clear done.
                if session.tab == .inbox && tasks.count > 1 {
                    bulkBar("Accept all \(tasks.count)", icon: "checkmark.circle") {
                        for t in tasks { session.store.acceptFromInbox(t.id) }
                    }
                }
                if session.tab == .done && tasks.contains(where: { $0.status == .done }) {
                    bulkBar("Archive all done", icon: "archivebox") {
                        for t in tasks where t.status == .done {
                            session.store.setStatus(t.id, .archived)
                        }
                    }
                }
                if tasks.isEmpty {
                    Text(emptyText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.faint)
                        .padding(30)
                }
                ForEach(tasks) { task in
                    Button(action: { session.selectedTaskId = task.id }) {
                        TaskCardRow(session: session, task: task)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Theme.glassBorder.opacity(0.5))
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func bulkBar(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button(action: action) {
                Label(title, systemImage: icon).font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 18).padding(.vertical, 6)
        .background(Color.white.opacity(0.02))
    }

    private var emptyText: String {
        switch session.tab {
        case .board: return "No tasks. Add one above, or ⌘-paste a braindump via “From prompt”."
        case .inbox: return "Inbox empty — AI-created tasks land here for your accept."
        case .done: return "Nothing finished yet."
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
                        Text("Nothing yet — run a task and every gate decision lands here.")
                            .font(.system(size: 12)).foregroundStyle(Theme.faint).padding(24)
                    }
                    ForEach(events) { e in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: e.icon)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.muted)
                                .frame(width: 16)
                            Text(e.text)
                                .font(.system(size: 11.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(e.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.faint)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 6)
                        Divider().overlay(Theme.glassBorder.opacity(0.4))
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
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            .overlay(Divider().overlay(Theme.glassBorder), alignment: .top)
        }
    }

    // MARK: - Decompose flow (FR27)

    private var decomposeView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: { session.decomposeMode = false }) {
                    Label("Back", systemImage: "chevron.left").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.muted)
                Spacer()
                Text("Create tasks from a prompt").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.top, 14)

            if session.decomposePreview.isEmpty {
                TextEditor(text: $session.decomposeText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        if session.decomposeText.isEmpty {
                            Text("Paste meeting notes, a Slack thread, an email, or just braindump…")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                                .padding(14).allowsHitTesting(false)
                        }
                    }
                HStack {
                    Spacer()
                    Button(action: { session.runDecompose() }) {
                        HStack(spacing: 6) {
                            if session.decomposeBusy { ProgressView().controlSize(.small) }
                            Text(session.decomposeBusy ? "Splitting…" : "Split into tasks")
                        }
                    }
                    .disabled(session.decomposeBusy || session.decomposeText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Text("Uncheck anything you don't want, then confirm:")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(session.decomposePreview.enumerated()), id: \.offset) { i, t in
                            HStack(alignment: .top, spacing: 8) {
                                Toggle("", isOn: Binding(
                                    get: { session.decomposeKeep.contains(i) },
                                    set: { on in
                                        if on { session.decomposeKeep.insert(i) }
                                        else { session.decomposeKeep.remove(i) }
                                    }
                                )).labelsHidden().toggleStyle(.checkbox)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title).font(.system(size: 12.5, weight: .medium))
                                    if let d = t.description, !d.isEmpty {
                                        Text(d).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                HStack {
                    Button("Start over") { session.decomposePreview = [] }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted).font(.system(size: 12))
                    Spacer()
                    Button("Create \(session.decomposeKeep.count) task\(session.decomposeKeep.count == 1 ? "" : "s")") {
                        session.confirmDecompose()
                    }
                    .disabled(session.decomposeKeep.isEmpty)
                }
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 12)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Footer / close

    private var footer: some View {
        HStack(spacing: 8) {
            let running = session.runner.activeRunIds.count
            Circle()
                .fill(running > 0 ? Theme.accent : Theme.success)
                .frame(width: 6, height: 6)
            Text(running > 0 ? "\(running) run\(running == 1 ? "" : "s") active" : "Idle")
                .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            if let status = session.pullStatus {
                Text("·  \(status)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer()
            if session.showSettings {
                // On the settings page the gear is pointless — offer jumps to
                // the two overlays instead.
                Button(action: { session.openAskHandler?() }) {
                    Image(systemName: "sparkle").font(.system(size: 14)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                Button(action: { session.showSettings = false }) {
                    Image(systemName: "checklist").font(.system(size: 14)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: { session.showSettings = true }) {
                    Image(systemName: "gearshape").font(.system(size: 14)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .overlay(Divider().overlay(Theme.glassBorder), alignment: .top)
    }

    private var closeButton: some View {
        Button(action: { session.dismissHandler?() }) {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Theme.muted)
                .padding(4)
                .background(Circle().fill(Theme.field))
                .overlay(Circle().strokeBorder(Theme.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Close")
    }
}

// MARK: - Card row (FR21/FR23)

private struct TaskCardRow: View {
    @ObservedObject var session: TaskBoardSession
    let task: TaskItem
    @State private var hovering = false
    /// Custom tooltip: .help() never fires on a nonactivating panel.
    @State private var hoverTip: String?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: task.source.icon)
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
                .frame(width: 14)
                .onHover { inside in
                    hoverTip = inside ? task.source.displayName
                                      : (hoverTip == task.source.displayName ? nil : hoverTip)
                }

            priorityChip

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if task.isPinned {
                        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(Theme.accent)
                    }
                    Text(task.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    if task.possibleDuplicateOf != nil {
                        Text("dup?")
                            .font(.system(size: 8.5, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                            .foregroundStyle(.orange)
                            .help("Looks like existing work — open to merge or dismiss")
                    }
                }
                HStack(spacing: 6) {
                    ForEach(task.labels.prefix(3), id: \.self) { label in
                        Text(label)
                            .font(.system(size: 9.5))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(Theme.field))
                            .foregroundStyle(Theme.muted)
                    }
                    if !task.aiRationale.isEmpty {
                        Text(task.aiRationale)
                            .font(.system(size: 10)).italic()
                            .foregroundStyle(Theme.faint).lineLimit(1)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                statusBadge
                Text(Self.addedLabel(task.createdAt))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.faint)
            }

            if hovering { hoverActions }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(hovering ? Color.white.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover {
            hovering = $0
            if !$0 { hoverTip = nil }
        }
        .overlay(alignment: .top) {
            if let tip = hoverTip {
                Text(tip)
                    .font(.system(size: 10))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color(red: 0.16, green: 0.17, blue: 0.2)))
                    .overlay(Capsule().strokeBorder(Theme.glassBorderHi, lineWidth: 1))
                    .foregroundStyle(Theme.fg.opacity(0.9))
                    .offset(y: -13)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
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
        Text(task.aiPriority.rawValue)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(priorityColor.opacity(0.18)))
            .foregroundStyle(priorityColor)
    }

    private var priorityColor: Color {
        switch task.aiPriority {
        case .p0: return Theme.danger
        case .p1: return .orange
        case .p2: return Theme.accent
        case .p3: return Theme.muted
        }
    }

    @ViewBuilder private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch task.status {
            case .executing: return ("Running", Theme.accent)
            case .planning: return ("Planning", Theme.accent)
            case .awaitingPlanApproval: return ("Plan review", .orange)
            case .awaitingReview: return ("Review", .orange)
            case .failed: return ("Failed", Theme.danger)
            case .queued: return ("Queued", Theme.muted)
            case .done: return ("Done", Theme.success)
            case .inbox: return ("New", Theme.accent)
            default: return ("", .clear)
            }
        }()
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .background(Capsule().fill(color.opacity(0.16)))
                .foregroundStyle(color)
        }
    }

    @ViewBuilder private var hoverActions: some View {
        HStack(spacing: 8) {
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
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { inside in
            hoverTip = inside ? help : (hoverTip == help ? nil : hoverTip)
        }
    }
}
