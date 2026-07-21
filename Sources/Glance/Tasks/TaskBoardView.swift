import SwiftUI

/// Task board app window (PRD V2 F1), light design (DS tokens).
/// Layout: floating tab pill over the active surface (spatial canvas / inbox
/// list / done history) → footer. Selecting a task swaps in
/// the sidebar + detail pane (edit, plan gate, run stream, review gate).
struct TaskBoardView: View {
    @ObservedObject var session: TaskBoardSession
    @ObservedObject var store: TaskStore

    /// Clearance below the floating pill for the list-style tabs.
    static let pillInset: CGFloat = 60

    var body: some View {
        VStack(spacing: 0) {
            if session.showAgents {
                AgentManagementView(session: session, onClose: { session.showAgents = false })
            } else if session.showSettings {
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
                            CanvasView(session: session, store: store, mode: .inbox)
                        case .review:
                            ReviewQueueView(session: session, store: store)
                                .padding(.top, Self.pillInset)
                        case .done:
                            DoneHistoryView(session: session, store: store)
                                .padding(.top, Self.pillInset)
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
                // Flatten first: otherwise the panel shadow renders per inner
                // card (it traces every opaque sub-shape), giving each section a
                // spurious drop shadow. Grouped, it shadows only the panel edge.
                .compositingGroup()
                .shadow(color: .black.opacity(0.12), radius: 16, x: -6)
                .transition(.move(edge: .trailing))
                .onExitCommand { session.selectedTaskId = nil }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if session.showSettings || session.showAgents {
                // On a full-page surface the gear/agents icons are pointless —
                // offer jumps to the ask overlay and back to the board instead.
                footerIcon("sparkle", help: "Open the ask overlay") { session.openAskHandler?() }
                footerIcon("checklist", help: "Back to the board") {
                    session.showSettings = false
                    session.showAgents = false
                }
            } else {
                footerIcon("person.2", help: "AI Agents") { session.showAgents = true }
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
