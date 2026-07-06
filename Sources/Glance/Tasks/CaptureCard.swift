import SwiftUI

/// Floating quick-capture card (N key / pill "+"). One form, always fully
/// open: title + description + agent/model/due. Leave any of it blank and
/// AI fills the gap from the title alone (existing `enrich` behavior) —
/// "Create with AI" and plain Enter are the same action, just two ways to
/// trigger it. Esc dismisses. No separate decompose window here anymore.
struct CaptureCard: View {
    @ObservedObject var session: TaskBoardSession
    @FocusState private var titleFocused: Bool
    @FocusState private var descriptionFocused: Bool

    @State private var description = ""
    @State private var agentId: UUID?
    @State private var runModel: String?
    @State private var dueAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "plus.circle.fill")
                    .font(DS.Typo.headline)
                    .foregroundStyle(DS.accentText)
                TextField("", text: $session.quickAdd,
                          prompt: Text("Drop a task…").foregroundColor(DS.textTertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .tint(DS.accentText)
                    .focused($titleFocused)
                    .onSubmit { submit() }
            }

            detailsSection
            footer
        }
        .padding(DS.Space.md)
        .frame(width: 520)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.large)
                .fill(DS.bg)
                .shadow(color: .black.opacity(0.14), radius: 24, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.large)
                .strokeBorder(DS.accent, lineWidth: 1)
        )
        .onAppear { titleFocused = true }
        .onExitCommand {
            session.quickAdd = ""
            session.showCapture = false
        }
    }

    // MARK: - Details (always open — leave blank for AI to fill)

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            TextEditor(text: $description)
                .font(DS.Typo.body)
                .scrollContentBackground(.hidden)
                .frame(height: 60)
                .dsField(focused: descriptionFocused)
                .focused($descriptionFocused)
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("Description — leave blank and AI writes one from the title")
                            .font(DS.Typo.body).foregroundStyle(DS.textTertiary)
                            .padding(.horizontal, DS.Space.xs + 4).padding(.top, DS.Space.xs + 2)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: DS.Space.xs) {
                AgentPickerChip(agentId: $agentId)
                ModelPickerChip(runModel: $runModel)
                DuePickerChip(dueAt: $dueAt)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("esc close")
                .font(DS.Typo.overline)
                .foregroundStyle(DS.textTertiary)

            Spacer()

            Button("Create") { submit(useAI: false) }
                .buttonStyle(DSSecondaryButtonStyle())
                .disabled(session.quickAdd.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Add exactly what's typed — no AI fill")

            Button(action: { submit(useAI: true) }) {
                Label("Create with AI", systemImage: "sparkles")
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .disabled(session.quickAdd.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("AI fills in whatever you left blank — description, labels, kind, agent")
        }
    }

    /// Plain Enter defaults to the AI path (existing fast-capture behavior);
    /// the two footer buttons make the choice explicit for mouse users.
    private func submit(useAI: Bool = true) {
        session.createTask(title: session.quickAdd, description: description,
                           agentId: agentId, runModel: runModel, dueAt: dueAt,
                           enrich: useAI)
        session.quickAdd = ""
        session.showCapture = false
    }
}
