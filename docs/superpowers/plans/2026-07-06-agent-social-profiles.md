# Agent Social Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the Agents section (Settings → Skill profiles) so each agent reads like a person — human name, avatar, bio, activity feed of completed runs, performance stats, and a per-run star rating — without leaving `TaskSettingsView`.

**Architecture:** `AgentProfile` gains a `humanName`; a 5th built-in (Analyst) is added to close a gap between shipped code and the current UI. `TaskRun` gains `agentId` (stamped at run creation, so history survives task reassignment) and `rating` (1–5, set from `TaskDetailView`). `TaskStore` gains read-only query helpers (`runs(forAgent:)`, `agentStats(_:)`, `feedEntries(forAgent:limit:)`) and one mutation (`setRating`) — all derived on read, no new persistence layer. `TaskSettingsView.agentRow` is redesigned around these queries; a new `StarRatingView` control is shared between the settings feed and `TaskDetailView`'s run history.

**Tech Stack:** Swift / SwiftUI, SwiftPM. No test framework in this repo — verification is `swift build` + `Scripts/build-app.sh` + manual AX-tree check (per the `glance-launch-and-ax-verify` memory; no screen recording available in this terminal).

**Spec:** `docs/superpowers/specs/2026-07-06-agent-social-profiles-design.md`

---

### Task 1: `AgentProfile` — human names + 5th built-in

**Files:**
- Modify: `Sources/Glance/Tasks/AgentProfile.swift:6-15` (struct), `:54-117` (`builtIns`)

- [ ] **Step 1: Add `humanName` field**

Replace lines 6-15:

```swift
struct AgentProfile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var humanName: String?        // display name (e.g. "Alex"); nil = show `name` only
    var icon: String              // emoji (e.g. "💻")
    var skills: String            // one-liner used for AI routing
    var systemPrompt: String      // appended to plan + execution system prompt
    var preferredModel: String?   // nil = task default (opus) / CLI default
    var allowedTools: [String]
    var isBuiltIn: Bool = false
}
```

- [ ] **Step 2: Add `humanName` to the 4 existing built-ins + add Analyst as a 5th**

Replace lines 54-117 (the whole `builtIns` array) with:

```swift
    static let builtIns: [AgentProfile] = [
        AgentProfile(
            id: UUID(uuidString: "A6E1C0DE-0001-4000-8000-000000000001")!,
            name: "Coder",
            humanName: "Alex",
            icon: "💻",
            skills: "Code changes in repos: bug fixes, features, refactors, tests, scripts.",
            systemPrompt: """
            You are a disciplined senior engineer. Method: read the relevant \
            code before changing it; make the smallest change that solves the \
            task; follow the repo's existing style and conventions; run tests \
            or a build when available; commit in small logical steps with \
            clear messages. Never leave the workspace in a broken state.
            """,
            preferredModel: nil,
            allowedTools: ["Bash", "Edit", "Write", "Read", "Glob", "Grep"],
            isBuiltIn: true
        ),
        AgentProfile(
            id: UUID(uuidString: "A6E1C0DE-0002-4000-8000-000000000002")!,
            name: "Writer",
            humanName: "Mia",
            icon: "✍️",
            skills: "Drafting: documents, replies, summaries, announcements, specs.",
            systemPrompt: """
            You are a sharp professional writer. Method: identify audience and \
            purpose first; lead with the point; keep it concise and concrete; \
            match the register the context calls for; produce a ready-to-use \
            draft, not an outline. Save deliverables as files in the workspace.
            """,
            preferredModel: "sonnet",
            allowedTools: ["Write", "Read", "Glob", "Grep"],
            isBuiltIn: true
        ),
        AgentProfile(
            id: UUID(uuidString: "A6E1C0DE-0003-4000-8000-000000000003")!,
            name: "Researcher",
            humanName: "Sam",
            icon: "🔍",
            skills: "Investigation: web research, comparisons, analysis, fact-finding.",
            systemPrompt: """
            You are a rigorous researcher. Method: search broadly before \
            concluding; prefer primary sources; note uncertainty honestly; \
            synthesize into a structured brief (findings, evidence, open \
            questions) rather than a link dump.
            """,
            preferredModel: "sonnet",
            allowedTools: ["WebSearch", "WebFetch", "Read", "Glob", "Grep"],
            isBuiltIn: true
        ),
        AgentProfile(
            id: UUID(uuidString: "A6E1C0DE-0004-4000-8000-000000000004")!,
            name: "Reviewer",
            humanName: "Jordan",
            icon: "✅",
            skills: "Critique: review diffs, PRs, documents; find risks and gaps.",
            systemPrompt: """
            You are an exacting reviewer. Method: understand intent before \
            judging; verify claims against the actual content (read the code/ \
            doc, don't assume); rank findings by severity; be specific about \
            location and fix; separate must-fix from nitpicks. You do not make \
            edits — you produce a review report.
            """,
            preferredModel: nil,
            allowedTools: ["Bash", "Read", "Glob", "Grep"],
            isBuiltIn: true
        ),
        AgentProfile(
            id: UUID(uuidString: "A6E1C0DE-0005-4000-8000-000000000005")!,
            name: "Analyst",
            humanName: "Priya",
            icon: "📊",
            skills: "Writes and optimizes SQL against analytics databases; explores schemas, builds correct joins.",
            systemPrompt: """
            You are a careful data analyst. Method: explore the schema before \
            writing a query; prefer explicit joins and named CTEs over dense \
            one-liners; sanity-check row counts and null handling; explain \
            what a query returns and any assumptions behind it.
            """,
            preferredModel: "opus",
            allowedTools: ["Bash", "Read", "Glob", "Grep"],
            isBuiltIn: true
        )
    ]
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: succeeds. `Reset to shipped definition` (`TaskSettingsView.swift:540`) still matches by `name`, unaffected.

- [ ] **Step 4: Commit**

```bash
git add Sources/Glance/Tasks/AgentProfile.swift
git commit -m "feat(agents): add humanName field and Analyst built-in"
```

### Task 2: Preferences migration — backfill humanName + add Analyst for existing installs

**Files:**
- Modify: `Sources/Glance/Settings/Preferences.swift:192-206`

- [ ] **Step 1: Extend the persisted-agents migration block**

Replace lines 192-206:

```swift
        if let data = defaults.data(forKey: Keys.agents),
           var decoded = try? JSONDecoder().decode([AgentProfile].self, from: data),
           !decoded.isEmpty {
            // Migrate pre-emoji profiles (icons were SF-Symbol names).
            var migrated = false
            for i in decoded.indices where decoded[i].hasLegacyIcon {
                decoded[i].icon = AgentProfile.emojiFor(legacyIcon: decoded[i].icon,
                                                        name: decoded[i].name)
                migrated = true
            }
            // Backfill humanName on built-ins persisted before this field existed.
            for i in decoded.indices where decoded[i].isBuiltIn && decoded[i].humanName == nil {
                if let shipped = AgentProfile.builtIns.first(where: { $0.id == decoded[i].id }) {
                    decoded[i].humanName = shipped.humanName
                    migrated = true
                }
            }
            // Add any built-ins shipped after this install's first launch (e.g. Analyst).
            let knownIds = Set(decoded.map(\.id))
            for shipped in AgentProfile.builtIns where !knownIds.contains(shipped.id) {
                decoded.append(shipped)
                migrated = true
            }
            agents = decoded
            if migrated, let data = try? JSONEncoder().encode(decoded) {
                defaults.set(data, forKey: Keys.agents)
            }
        } else {
            agents = AgentProfile.builtIns
            // didSet doesn't fire during init — persist the seed explicitly.
            if let data = try? JSONEncoder().encode(AgentProfile.builtIns) {
                defaults.set(data, forKey: Keys.agents)
            }
        }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Glance/Settings/Preferences.swift
git commit -m "feat(agents): migrate existing installs to humanName + Analyst"
```

### Task 3: `TaskRun` — `agentId` + `rating`

**Files:**
- Modify: `Sources/Glance/Tasks/TaskModels.swift:244-260`

- [ ] **Step 1: Add the two fields**

Replace lines 244-260:

```swift
struct TaskRun: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var taskId: UUID
    var agentId: UUID?                // stamped from task.agentId at run creation
    var state: RunState = .planning
    var plan: String = ""
    var planApprovedAt: Date?
    var transcriptPath: String?
    var claudeSessionId: String?
    var workspacePath: String = ""
    var branchName: String?           // code runs: the worktree branch
    var artifacts: [RunArtifact] = []
    var startedAt: Date = Date()
    var endedAt: Date?
    var failureReason: String?
    var rating: Int?                  // 1-5 stars, nil = unrated
    /// Live progress tail while executing (not persisted verbatim — capped).
    var progressTail: String = ""
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: succeeds — `agentId` and `rating` are optional with an implicit `nil` default, so the existing `TaskRunner.swift:61` call site (`TaskRun(taskId:workspacePath:)`, no `agentId` yet) keeps compiling unchanged.

- [ ] **Step 3: Commit**

```bash
git add Sources/Glance/Tasks/TaskModels.swift
git commit -m "feat(agents): add TaskRun.agentId and TaskRun.rating"
```

### Task 4: Stamp `agentId` at run creation

**Files:**
- Modify: `Sources/Glance/Tasks/TaskRunner.swift:61`

- [ ] **Step 1: Pass the task's agent into the new run**

Replace line 61:

```swift
        let run = store.addRun(TaskRun(taskId: taskId, agentId: task.agentId, workspacePath: task.workspacePath ?? ""))
```

(`task` is already in scope as `var task` from the `guard var task = store.task(taskId) ...` a few lines above — see `TaskRunner.swift:46`.)

- [ ] **Step 2: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Glance/Tasks/TaskRunner.swift
git commit -m "feat(agents): stamp agentId onto TaskRun at creation"
```

### Task 5: `TaskStore` — per-agent queries + rating mutation

**Files:**
- Modify: `Sources/Glance/Tasks/TaskStore.swift` (add after `run(_:)` at line 262, before `failOrphanedRuns()`)

- [ ] **Step 1: Add `AgentStats`, the three query helpers, and `setRating`**

Insert after line 262 (`func run(_ id: UUID) -> TaskRun? { runs.first { $0.id == id } }`):

```swift

    /// Runs stamped with `agentId`, most recent first.
    func runs(forAgent agentId: UUID) -> [TaskRun] {
        runs.filter { $0.agentId == agentId }.sorted { $0.startedAt > $1.startedAt }
    }

    struct AgentStats: Equatable {
        var totalRuns = 0
        var successRate: Double?   // fraction 0...1; nil = no terminal runs yet
        var avgRating: Double?     // nil = no rated runs yet
    }

    /// Derived on read — no separate persistence, matches the run history.
    func agentStats(_ agentId: UUID) -> AgentStats {
        let agentRuns = runs(forAgent: agentId)
        var stats = AgentStats()
        stats.totalRuns = agentRuns.count
        let terminal = agentRuns.filter { $0.state == .succeeded || $0.state == .failed }
        if !terminal.isEmpty {
            let succeeded = terminal.filter { $0.state == .succeeded }.count
            stats.successRate = Double(succeeded) / Double(terminal.count)
        }
        let rated = agentRuns.compactMap(\.rating)
        if !rated.isEmpty {
            stats.avgRating = Double(rated.reduce(0, +)) / Double(rated.count)
        }
        return stats
    }

    /// Last `limit` runs for an agent, paired with their task's title (feed rows).
    /// A run whose task was since deleted still shows, titled "Deleted task".
    func feedEntries(forAgent agentId: UUID, limit: Int = 20) -> [(run: TaskRun, taskTitle: String)] {
        runs(forAgent: agentId).prefix(limit).map { run in
            (run, task(run.taskId)?.title ?? "Deleted task")
        }
    }

    func setRating(runId: UUID, rating: Int?) {
        guard var r = run(runId) else { return }
        r.rating = rating
        updateRun(r)
    }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Glance/Tasks/TaskStore.swift
git commit -m "feat(agents): add per-agent stats/feed queries and setRating"
```

### Task 6: `StarRatingView` — shared 1-5 star control

**Files:**
- Create: `Sources/Glance/Tasks/StarRatingView.swift`

- [ ] **Step 1: Create the view**

```swift
import SwiftUI

/// Tappable 1–5 star rating control. `rating` nil renders all-empty stars.
/// Tapping star N sets the rating to N; tapping the currently-set star clears it.
struct StarRatingView: View {
    var rating: Int?
    var onSet: (Int?) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: (rating ?? 0) >= i ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle((rating ?? 0) >= i ? .yellow : DS.textTertiary)
                    .onTapGesture {
                        onSet(rating == i ? nil : i)
                    }
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: succeeds (nothing uses it yet).

- [ ] **Step 3: Commit**

```bash
git add Sources/Glance/Tasks/StarRatingView.swift
git commit -m "feat(agents): add StarRatingView control"
```

### Task 7: Wire rating into `TaskDetailView` run history

**Files:**
- Modify: `Sources/Glance/Tasks/TaskDetailView.swift:897-924` (`runHistory`)

- [ ] **Step 1: Add the star control to each terminal run row**

Replace lines 897-924:

```swift
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
                            if r.state.isTerminal {
                                StarRatingView(rating: r.rating) { newRating in
                                    session.store.setRating(runId: r.id, rating: newRating)
                                }
                            }
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
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Glance/Tasks/TaskDetailView.swift
git commit -m "feat(agents): rate completed runs from the task detail view"
```

### Task 8: `TaskSettingsView` — profile-style `agentRow` + editor field

**Files:**
- Modify: `Sources/Glance/Tasks/TaskSettingsView.swift:446-477` (`agentRow`), `:492-505` (top of `agentEditor`)

- [ ] **Step 1: Replace `agentRow` (lines 446-477) with the profile-card version + two new helpers**

```swift
    @ViewBuilder private func agentRow(_ agent: AgentProfile) -> some View {
        let editing = editingAgentId == agent.id
        let stats = session.store.agentStats(agent.id)
        Hover { hovering in
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.xs) {
                    Text(agent.icon)
                        .font(DS.Typo.headline)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(DS.surface))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: DS.Space.xxs) {
                            Text(agent.humanName ?? agent.name).font(DS.Typo.label)
                            if agent.humanName != nil {
                                Text("· \(agent.name)").font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
                            }
                            if agent.isBuiltIn {
                                dsBadge("built-in", tint: DS.textTertiary, soft: DS.surface)
                            }
                        }
                        Text(agent.skills).font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(agent.preferredModel ?? "auto")
                        .font(DS.Typo.mono).foregroundStyle(DS.textTertiary)
                    Button(editing ? "Done" : "Edit") {
                        editingAgentId = editing ? nil : agent.id
                    }
                    .buttonStyle(.plain).font(DS.Typo.label).foregroundStyle(DS.accentText)
                }

                Text(agentStatsLine(stats))
                    .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
                    .padding(.leading, 44)

                if !editing {
                    let preview = session.store.feedEntries(forAgent: agent.id, limit: 2)
                    if !preview.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(preview, id: \.run.id) { entry in
                                feedRow(entry, interactive: false)
                            }
                        }
                        .padding(.leading, 44)
                    }
                } else {
                    let full = session.store.feedEntries(forAgent: agent.id, limit: 20)
                    if !full.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            overline("Activity")
                            ForEach(full, id: \.run.id) { entry in
                                feedRow(entry, interactive: true)
                            }
                        }
                    }
                    Divider()
                    agentEditor(agent)
                }
            }
            .padding(.vertical, DS.Space.xs).padding(.horizontal, DS.Space.sm)
            .background(RoundedRectangle(cornerRadius: DS.Radius.medium)
                .fill(hovering && !editing ? DS.surfaceHover : DS.bg))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium)
                .strokeBorder(DS.border, lineWidth: 1))
        }
    }

    private func agentStatsLine(_ stats: TaskStore.AgentStats) -> String {
        var parts = ["\(stats.totalRuns) task\(stats.totalRuns == 1 ? "" : "s")"]
        if let rate = stats.successRate {
            parts.append("\(Int((rate * 100).rounded()))% success")
        }
        if let avg = stats.avgRating {
            parts.append(String(format: "%.1f★ avg", avg))
        }
        return parts.joined(separator: " · ")
    }

    private static let feedRelativeTime: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    @ViewBuilder private func feedRow(_ entry: (run: TaskRun, taskTitle: String), interactive: Bool) -> some View {
        HStack(spacing: DS.Space.xxs) {
            Image(systemName: entry.run.state == .succeeded ? "checkmark.circle" : "xmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(entry.run.state == .succeeded ? DS.success : DS.danger)
            Text(entry.taskTitle).font(DS.Typo.caption).foregroundStyle(DS.textSecondary).lineLimit(1)
            if let rating = entry.run.rating {
                Text(String(repeating: "★", count: rating)).font(DS.Typo.caption).foregroundStyle(.yellow)
            }
            Spacer()
            Text(Self.feedRelativeTime.localizedString(for: entry.run.startedAt, relativeTo: Date()))
                .font(DS.Typo.caption).foregroundStyle(DS.textTertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard interactive else { return }
            session.selectedTaskId = entry.run.taskId
            onClose()
        }
    }
```

- [ ] **Step 2: Add `humanName` field to `agentEditor`**

In `agentEditor(_:)`, replace the first `HStack` (lines 493-505):

```swift
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                TextField("Name", text: bind(\.name))
                    .textFieldStyle(.roundedBorder).font(DS.Typo.caption).frame(width: 110)
                TextField("Human name (optional)", text: Binding(
                    get: { bind(\.humanName).wrappedValue ?? "" },
                    set: { bind(\.humanName).wrappedValue = $0.isEmpty ? nil : $0 }
                ))
                    .textFieldStyle(.roundedBorder).font(DS.Typo.caption).frame(width: 130)
                TextField("Emoji", text: bind(\.icon))
                    .textFieldStyle(.roundedBorder).font(DS.Typo.caption).frame(width: 60)
                Picker("", selection: bind(\.preferredModel)) {
                    Text("auto").tag(String?.none)
                    ForEach(["haiku", "sonnet", "opus"], id: \.self) { m in
                        Text(m).tag(String?.some(m))
                    }
                }
                .labelsHidden().controlSize(.small).frame(width: 90)
            }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/Glance/Tasks/TaskSettingsView.swift
git commit -m "feat(agents): profile-card agentRow with stats, feed, and humanName editor field"
```

### Task 9: Final build + manual verification

**Files:** none (verification only)

- [ ] **Step 1: Full app build**

Run: `Scripts/build-app.sh && open build/Glance.app`
Expected: builds clean, app launches.

- [ ] **Step 2: Manual checks (AX tree — no screen recording available per `glance-launch-and-ax-verify` memory)**

- Open Settings → Agents: 5 built-ins render (Coder/Alex, Writer/Mia, Researcher/Sam, Reviewer/Jordan, Analyst/Priya), each showing `"0 tasks"` and no success/rating segments (no runs yet).
- Create a task, assign an agent, run it to completion (succeeded or failed).
- Reopen Settings → Agents: the assigned agent's stats line now shows `"1 task · 100% success"` (or `0%` if failed) and a feed row with the task's title + relative time.
- In `TaskDetailView` for that task, the completed run row shows 5 tappable stars; tap star 4 → rating persists (reopen the task, stars still show 4/5 filled).
- Reopen Settings → Agents: the same agent's stats line now includes `"4.0★ avg"`, and the feed row shows `★★★★`.
- Tap the feed row in the *expanded* agent card → `TaskDetailView` opens for that task (settings closes). Tap the same row in the *collapsed* preview (2-line) → nothing happens (non-interactive).
- Add a custom agent manually (`humanName` stays nil) → renders with role name only, no crash, editor shows an empty "Human name" field.

- [ ] **Step 3: Commit (only if verification turned up fixes)**

If manual verification required follow-up fixes, commit them individually with the same message-style convention (`fix(agents): ...`).
