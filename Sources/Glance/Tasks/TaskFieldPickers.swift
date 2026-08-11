import SwiftUI

/// Binding-based task field pickers — same chip look as TaskDetailView's
/// inline pickers, but bound to arbitrary state instead of mutating a live
/// TaskItem. Used by CaptureCard (task doesn't exist yet); TaskDetailView
/// keeps its own task-mutating versions since those write straight through
/// to the store on every change.
enum TaskFieldPicker {

    /// Shared chip chrome: dashed border + muted text when unset, solid when set.
    static func chip<L: View>(isSet: Bool, @ViewBuilder label: () -> L) -> some View {
        let content = label()
        return Hover { hovering in
            content
                .font(DS.Typo.caption)
                .fixedSize()
                .foregroundStyle(isSet ? DS.textSecondary : DS.textTertiary)
                .padding(.horizontal, DS.Space.xxs + 2).padding(.vertical, 3)
                .background(Capsule().fill(hovering ? DS.surfaceHover : DS.surface))
                .overlay(Capsule().strokeBorder(DS.border,
                                                style: StrokeStyle(lineWidth: 1, dash: isSet ? [] : [3, 2])))
        }
    }
}

/// Agent picker — "None (generic)" plus the user's roster.
struct AgentPickerChip: View {
    @Binding var agentId: UUID?
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        let current = prefs.agent(agentId)
        Menu {
            Button("None (generic)") { agentId = nil }
            Divider()
            ForEach(prefs.agents) { agent in
                Button("\(agent.icon) \(agent.name) — \(agent.skills)") { agentId = agent.id }
            }
        } label: {
            TaskFieldPicker.chip(isSet: current != nil) {
                Text(current == nil ? "🤖 agent" : "\(current!.icon) \(current!.name)")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which skill profile runs this task — leave unset to let AI route it")
    }
}

/// Model override — provider default plus any named choices it supports.
struct ModelPickerChip: View {
    @Binding var runModel: String?
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        let provider = prefs.askBackend
        let current = ModelCatalog.presentedChoice(for: runModel, provider: provider)
        Menu {
            ForEach(ModelCatalog.choices(for: provider), id: \.rawValue) { choice in
                Button(label(choice, provider: provider)) {
                    runModel = ModelCatalog.storedModel(afterSelecting: choice,
                                                        current: runModel,
                                                        provider: provider)
                }
            }
        } label: {
            TaskFieldPicker.chip(isSet: current != .automatic) {
                Label(label(current, provider: provider), systemImage: "cpu")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Model for AI runs on this task")
    }

    private func label(_ choice: AutomationModelChoice, provider: AskBackendKind) -> String {
        guard choice != .automatic else { return ModelCatalog.label(for: choice, provider: provider) }
        if let resolved = ModelCatalog.shared.displayName(for: choice.rawValue) {
            return "\(choice.rawValue) — \(resolved)"
        }
        return choice.rawValue
    }
}

/// Due-date picker — popover date picker, matches TaskDetailView's.
struct DuePickerChip: View {
    @Binding var dueAt: Date?
    @State private var showPicker = false
    @State private var draft = Date()

    var body: some View {
        Button(action: {
            draft = dueAt ?? Calendar.current.startOfDay(for: Date())
            showPicker = true
        }) {
            TaskFieldPicker.chip(isSet: dueAt != nil) {
                if let due = dueAt {
                    let d = TaskCanvasCard.dueLabel(due)
                    Label(d.text, systemImage: "clock").foregroundStyle(d.color)
                } else {
                    Label("due…", systemImage: "clock")
                }
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            VStack(spacing: DS.Space.sm) {
                DatePicker("", selection: $draft, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                HStack {
                    if dueAt != nil {
                        Button("Clear") { dueAt = nil; showPicker = false }
                            .buttonStyle(DSSecondaryButtonStyle())
                    }
                    Spacer()
                    Button("Set due date") { dueAt = draft; showPicker = false }
                        .buttonStyle(DSPrimaryButtonStyle())
                }
            }
            .padding(DS.Space.sm)
            .frame(width: 260)
        }
        .help("Due date")
    }
}
