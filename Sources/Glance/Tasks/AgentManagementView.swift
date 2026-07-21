import SwiftUI

/// Dedicated home for creating and managing AI agents — a full-page
/// master/detail surface (gallery on the left, roomy editor on the right)
/// that supersedes the cramped Settings ▸ Agents inline editor.
///
/// Design goals: one obvious place to add an agent (AI-designed or by hand),
/// a scannable roster with avatars + at-a-glance model/tool/stat cues, and an
/// editor with room to breathe. All CRUD mutates `Preferences.shared.agents`
/// directly (self-persisting via its didSet); AI design routes through
/// `session.generateAgent`.
struct AgentManagementView: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject var session: TaskBoardSession
    var onClose: () -> Void

    @State private var selectedId: UUID?
    @State private var query = ""
    @State private var showAISheet = false

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(DS.divider)
            HStack(spacing: 0) {
                roster
                Divider().overlay(DS.divider)
                detail
            }
            .frame(maxHeight: .infinity)
        }
        .onAppear { if selectedId == nil { selectedId = prefs.agents.first?.id } }
        .sheet(isPresented: $showAISheet) {
            AIDesignSheet(session: session) { newId in
                selectedId = newId
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            BackButton(label: "Board", action: onClose)
            VStack(alignment: .leading, spacing: 0) {
                Text("AI Agents").font(DS.Typo.headline).foregroundStyle(DS.textPrimary)
                Text("Your roster of specialists — routed to tasks automatically, overridable per task.")
                    .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
            }
            Spacer()
            Button(action: { showAISheet = true }) {
                Label("Design with AI", systemImage: "sparkles")
            }
            .buttonStyle(DSSecondaryButtonStyle())
            .pointerCursor()
            Button(action: addManualAgent) {
                Label("New agent", systemImage: "plus")
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .pointerCursor()
        }
        .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
    }

    // MARK: Roster (master)

    private var filtered: [AgentProfile] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return prefs.agents }
        return prefs.agents.filter {
            $0.name.lowercased().contains(q)
                || ($0.humanName ?? "").lowercased().contains(q)
                || $0.skills.lowercased().contains(q)
        }
    }

    private var roster: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.xxs) {
                Image(systemName: "magnifyingglass")
                    .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
                TextField("Search agents", text: $query)
                    .textFieldStyle(.plain).font(DS.Typo.label)
            }
            .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xs)
            .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.surface))
            .padding(DS.Space.xs + 2)

            ScrollView {
                LazyVStack(spacing: DS.Space.xxs + 2) {
                    ForEach(filtered) { agent in
                        rosterCard(agent)
                    }
                    if filtered.isEmpty {
                        Text("No agents match “\(query)”.")
                            .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
                            .padding(.top, DS.Space.md)
                    }
                }
                .padding(.horizontal, DS.Space.xs + 2)
                .padding(.bottom, DS.Space.md)
            }
            Divider().overlay(DS.divider)
            HStack {
                Text("\(prefs.agents.count) agent\(prefs.agents.count == 1 ? "" : "s")")
                    .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
                Spacer()
            }
            .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xs)
        }
        .frame(width: 280)
        .background(DS.surface.opacity(0.4))
    }

    private func rosterCard(_ agent: AgentProfile) -> some View {
        let selected = selectedId == agent.id
        return Hover { hovering in
            Button(action: { selectedId = agent.id }) {
                HStack(spacing: DS.Space.xs + 2) {
                    AgentAvatarView(agent: agent, size: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: DS.Space.xxs) {
                            Text(agent.displayName).font(DS.Typo.label)
                                .foregroundStyle(DS.textPrimary).lineLimit(1)
                            if agent.isBuiltIn {
                                Text("built-in").font(DS.Typo.overline)
                                    .foregroundStyle(DS.textTertiary)
                            }
                        }
                        Text(agent.humanName != nil ? agent.name : agent.skills)
                            .font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(agent.preferredModel ?? "auto")
                        .font(DS.Typo.overline).foregroundStyle(DS.textTertiary)
                }
                .padding(.horizontal, DS.Space.xs + 2).padding(.vertical, DS.Space.xs)
                .background(RoundedRectangle(cornerRadius: DS.Radius.medium)
                    .fill(selected ? DS.accentSoft : (hovering ? DS.surfaceHover : .clear)))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium)
                    .strokeBorder(selected ? DS.accent.opacity(0.4) : .clear, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: Detail (editor)

    @ViewBuilder private var detail: some View {
        if let agent = prefs.agents.first(where: { $0.id == selectedId }) {
            AgentEditorPane(session: session, agent: agent) {
                // Deleted — pick a neighbour.
                selectedId = prefs.agents.first?.id
            }
            .id(agent.id) // fresh field focus per agent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.bg)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.sm) {
            Image(systemName: "person.2")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(DS.textTertiary)
            Text("Select an agent to edit")
                .font(DS.Typo.body).foregroundStyle(DS.textSecondary)
            Text("or create a new one — design it with AI or build it by hand.")
                .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
            HStack(spacing: DS.Space.xs) {
                Button(action: { showAISheet = true }) {
                    Label("Design with AI", systemImage: "sparkles")
                }
                .buttonStyle(DSSecondaryButtonStyle()).pointerCursor()
                Button(action: addManualAgent) {
                    Label("New agent", systemImage: "plus")
                }
                .buttonStyle(DSPrimaryButtonStyle()).pointerCursor()
            }
            .padding(.top, DS.Space.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.bg)
    }

    // MARK: Actions

    private func addManualAgent() {
        let fresh = AgentProfile(name: "New agent", icon: "🤖",
                                 skills: "Describe what this agent is best at",
                                 systemPrompt: "", preferredModel: nil,
                                 allowedTools: ["Read", "Glob", "Grep"])
        prefs.agents.append(fresh)
        selectedId = fresh.id
    }
}

// MARK: - Editor pane

/// The right-hand editor for one agent. Reads/writes straight into
/// `Preferences.shared.agents` so edits persist immediately.
private struct AgentEditorPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var catalog = ModelCatalog.shared
    @ObservedObject var session: TaskBoardSession
    let agent: AgentProfile
    var onDelete: () -> Void

    @State private var confirmingDelete = false

    private var idx: Int? { prefs.agents.firstIndex(where: { $0.id == agent.id }) }

    private func bind<T>(_ keyPath: WritableKeyPath<AgentProfile, T>) -> Binding<T> {
        Binding(
            get: { prefs.agents.first { $0.id == agent.id }?[keyPath: keyPath] ?? agent[keyPath: keyPath] },
            set: { newValue in
                guard let i = idx else { return }
                prefs.agents[i][keyPath: keyPath] = newValue
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                identityHeader
                Divider().overlay(DS.divider)
                identityFields
                skillsField
                systemPromptField
                toolsField
                statsAndFeed
                Divider().overlay(DS.divider)
                dangerRow
            }
            .padding(DS.Space.lg)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Identity header (live preview)

    private var identityHeader: some View {
        HStack(spacing: DS.Space.md) {
            AgentAvatarView(agent: agent, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DS.Space.xs) {
                    Text(agent.displayName).font(DS.Typo.title).foregroundStyle(DS.textPrimary)
                    if agent.isBuiltIn {
                        dsBadge("built-in", tint: DS.textTertiary, soft: DS.surface)
                    }
                }
                Text(agent.humanName != nil ? "\(agent.name) · role" : "role")
                    .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
                HStack(spacing: DS.Space.xxs) {
                    dsBadge(modelLabel, tint: DS.accentText, soft: DS.accentSoft)
                    dsBadge("\(agent.allowedTools.count) tools", tint: DS.textSecondary, soft: DS.surface)
                }
                .padding(.top, 2)
            }
            Spacer()
        }
    }

    private var modelLabel: String {
        guard let m = agent.preferredModel else { return "auto model" }
        return catalog.displayName(for: m) ?? m
    }

    // MARK: Fields

    private var identityFields: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            fieldLabel("Identity")
            HStack(spacing: DS.Space.sm) {
                labeledField("Role", hint: "used for AI routing", width: 180) {
                    TextField("e.g. Coder", text: bind(\.name))
                        .textFieldStyle(.roundedBorder).font(DS.Typo.body)
                }
                labeledField("Display name", hint: "shown around the app", width: 150) {
                    TextField(agent.name, text: Binding(
                        get: { prefs.agents.first { $0.id == agent.id }?.humanName ?? "" },
                        set: { v in
                            guard let i = idx else { return }
                            let t = v.trimmingCharacters(in: .whitespaces)
                            prefs.agents[i].humanName = t.isEmpty ? nil : t
                        }
                    ))
                    .textFieldStyle(.roundedBorder).font(DS.Typo.body)
                }
                labeledField("Emoji", hint: nil, width: 70) {
                    TextField("🤖", text: bind(\.icon))
                        .textFieldStyle(.roundedBorder).font(DS.Typo.body)
                }
            }
            labeledField("Preferred model", hint: "the model its runs use", width: 220) {
                Picker("", selection: bind(\.preferredModel)) {
                    Text("Auto (task default)").tag(String?.none)
                    ForEach(["haiku", "sonnet", "opus"], id: \.self) { m in
                        Text(catalog.displayName(for: m) ?? m).tag(String?.some(m))
                    }
                }
                .labelsHidden().pickerStyle(.menu)
            }
        }
    }

    private var skillsField: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            fieldLabel("Skills")
            Text("A one-line description of what this agent is best at — the AI uses it to route tasks.")
                .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
            TextField("e.g. Backend APIs, SQL, careful with migrations", text: bind(\.skills))
                .textFieldStyle(.roundedBorder).font(DS.Typo.body)
        }
    }

    private var systemPromptField: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            fieldLabel("System prompt")
            Text("Appended to the plan + execution prompt for every run this agent performs.")
                .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
            TextEditor(text: bind(\.systemPrompt))
                .font(DS.Typo.mono)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
                .padding(DS.Space.xs)
                .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.codeBg))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.small)
                    .strokeBorder(DS.border, lineWidth: 1))
        }
    }

    private var toolsField: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            fieldLabel("Tools")
            Text("Least privilege — grant only what its work needs. Boundary actions (git push, PR/API writes) stay blocked for every agent.")
                .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
            WrapLayout(spacing: DS.Space.xs, lineSpacing: DS.Space.xs) {
                ForEach(AgentProfile.toolVocabulary, id: \.self) { tool in
                    toolChip(tool)
                }
            }
        }
    }

    private func toolChip(_ tool: String) -> some View {
        let on = (prefs.agents.first { $0.id == agent.id }?.allowedTools ?? []).contains(tool)
        return Hover { hovering in
            Button(action: {
                guard let i = idx else { return }
                if on { prefs.agents[i].allowedTools.removeAll { $0 == tool } }
                else if !prefs.agents[i].allowedTools.contains(tool) {
                    prefs.agents[i].allowedTools.append(tool)
                }
            }) {
                HStack(spacing: DS.Space.xxs) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(DS.Typo.caption)
                        .foregroundStyle(on ? DS.accentText : DS.textTertiary)
                    Text(tool).font(DS.Typo.label)
                        .foregroundStyle(on ? DS.textPrimary : DS.textSecondary)
                }
                .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xxs + 2)
                .background(Capsule().fill(on ? DS.accentSoft : (hovering ? DS.surfaceHover : DS.surface)))
                .overlay(Capsule().strokeBorder(on ? DS.accent.opacity(0.35) : DS.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: Stats + recent work

    @ViewBuilder private var statsAndFeed: some View {
        let stats = session.store.stats(forAgent: agent.id)
        let recent = session.store.recentRuns(forAgent: agent.id, limit: 8)
        if stats.totalRuns > 0 {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                fieldLabel("Track record")
                HStack(spacing: DS.Space.sm) {
                    statTile("\(stats.totalRuns)", "task\(stats.totalRuns == 1 ? "" : "s")")
                    if let pct = stats.successPercent { statTile("\(pct)%", "success") }
                    if let avg = stats.averageRating { statTile(String(format: "%.1f★", avg), "avg rating") }
                }
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        ForEach(recent) { run in feedRow(run) }
                    }
                    .padding(.top, DS.Space.xxs)
                }
            }
        }
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(DS.Typo.headline).foregroundStyle(DS.textPrimary)
            Text(label).font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
        }
        .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xs)
        .frame(minWidth: 84, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.surface))
    }

    private static let feedTime: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()

    private func feedRow(_ run: TaskRun) -> some View {
        Hover { hovering in
            HStack(spacing: DS.Space.xs) {
                Image(systemName: run.state == .succeeded ? "checkmark.circle.fill" : "xmark.circle")
                    .font(DS.Typo.overline)
                    .foregroundStyle(run.state == .succeeded ? DS.success : DS.textTertiary)
                Text(session.store.task(run.taskId)?.title ?? "(deleted task)")
                    .font(DS.Typo.caption).foregroundStyle(DS.textSecondary).lineLimit(1)
                if let stars = run.rating {
                    Text("\(stars)★").font(DS.Typo.caption).foregroundStyle(DS.warning)
                }
                Spacer()
                Text(Self.feedTime.localizedString(for: run.startedAt, relativeTo: Date()))
                    .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
            }
            .padding(.horizontal, DS.Space.xs).padding(.vertical, DS.Space.xxs)
            .background(RoundedRectangle(cornerRadius: DS.Radius.small)
                .fill(hovering ? DS.surfaceHover : .clear))
            .contentShape(Rectangle())
            .onTapGesture {
                session.selectedTaskId = run.taskId
                session.showAgents = false
            }
        }
    }

    // MARK: Danger row

    private var dangerRow: some View {
        HStack {
            if agent.isBuiltIn {
                Button("Reset to shipped definition") {
                    if let shipped = AgentProfile.builtIns.first(where: { $0.name == agent.name }),
                       let i = idx {
                        var restored = shipped
                        restored.id = agent.id
                        restored.isBuiltIn = true
                        prefs.agents[i] = restored
                    }
                }
                .buttonStyle(DSSecondaryButtonStyle()).pointerCursor()
                .help("Restore this built-in agent to how it shipped")
            } else if confirmingDelete {
                Text("Delete this agent?").font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
                Button("Cancel") { confirmingDelete = false }
                    .buttonStyle(DSSecondaryButtonStyle()).pointerCursor()
                Button("Delete", role: .destructive) {
                    prefs.agents.removeAll { $0.id == agent.id }
                    confirmingDelete = false
                    onDelete()
                }
                .buttonStyle(DSPrimaryButtonStyle()).pointerCursor()
            } else {
                Button(role: .destructive, action: { confirmingDelete = true }) {
                    Label("Delete agent", systemImage: "trash")
                }
                .buttonStyle(DSSecondaryButtonStyle()).pointerCursor()
            }
            Spacer()
        }
    }

    // MARK: Small helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(DS.Typo.overline).tracking(0.8)
            .foregroundStyle(DS.textTertiary)
    }

    private func labeledField<Content: View>(_ label: String, hint: String?, width: CGFloat,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: DS.Space.xxs) {
                Text(label).font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
                if let hint {
                    Text(hint).font(DS.Typo.overline).foregroundStyle(DS.textTertiary)
                }
            }
            content()
        }
        .frame(width: width, alignment: .leading)
    }
}

// MARK: - AI design sheet

/// Describe the agent you need; Opus designs the profile (persona, model,
/// least-privilege tools). On success the new agent is appended and selected.
private struct AIDesignSheet: View {
    @ObservedObject var session: TaskBoardSession
    var onCreated: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var request = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "sparkles").foregroundStyle(DS.accentText)
                Text("Design an agent with AI").font(DS.Typo.headline)
            }
            Text("Describe the specialist you need. Opus writes the persona, picks the model, and grants least-privilege tools. Review and tweak before first use.")
                .font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $request)
                .font(DS.Typo.body)
                .scrollContentBackground(.hidden)
                .frame(height: 90)
                .padding(DS.Space.xs)
                .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.surface))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.small)
                    .strokeBorder(DS.border, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if request.isEmpty {
                        Text("e.g. “SQL analyst for our metrics DB, careful with joins, read-only”")
                            .font(DS.Typo.body).foregroundStyle(DS.textTertiary)
                            .padding(DS.Space.xs + 4).allowsHitTesting(false)
                    }
                }

            if let error {
                Text(error).font(DS.Typo.caption).foregroundStyle(DS.danger)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(DSSecondaryButtonStyle()).pointerCursor()
                Button(action: generate) {
                    HStack(spacing: DS.Space.xxs) {
                        if busy { ProgressView().controlSize(.mini) }
                        Text(busy ? "Designing…" : "Generate")
                    }
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .pointerCursor()
                .disabled(busy || request.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DS.Space.lg)
        .frame(width: 460)
        .background(DS.bg)
    }

    private func generate() {
        let req = request.trimmingCharacters(in: .whitespaces)
        guard !req.isEmpty, !busy else { return }
        busy = true; error = nil
        session.generateAgent(request: req) { profile in
            busy = false
            guard let profile else {
                error = "Couldn't design an agent — try rephrasing."
                return
            }
            Preferences.shared.agents.append(profile)
            onCreated(profile.id)
            dismiss()
        }
    }
}
