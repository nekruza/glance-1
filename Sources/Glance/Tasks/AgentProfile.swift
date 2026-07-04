import Foundation

/// A skill profile for task execution: persona (system prompt), preferred
/// model, and tool allowlist. AI routes each new task to the best-fit profile
/// (user can override); TaskRunner applies the profile to plan + run.
struct AgentProfile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var icon: String              // SF Symbol
    var skills: String            // one-liner used for AI routing
    var systemPrompt: String      // appended to plan + execution system prompt
    var preferredModel: String?   // nil = task default (opus) / CLI default
    var allowedTools: [String]
    var isBuiltIn: Bool = false
}

extension AgentProfile {

    /// Resolve an AI-suggested agent name to a profile id (case-insensitive).
    static func idFor(name: String?) -> UUID? {
        guard let name, !name.isEmpty else { return nil }
        return Preferences.shared.agents
            .first { $0.name.lowercased() == name.lowercased() }?.id
    }

    /// The tool vocabulary the Agents editor offers. Boundary denies
    /// (git push / gh pr / gh api) are enforced by TaskRunner regardless.
    static let toolVocabulary = ["Bash", "Edit", "Write", "Read", "Glob", "Grep", "WebFetch", "WebSearch"]

    /// Shipped roster. Seeded into Preferences on first launch; edits persist
    /// as overrides, Reset restores these definitions (matched by name).
    // Stable ids: task.agentId references must survive relaunches and the
    // "never persisted yet" first-launch window.
    static let builtIns: [AgentProfile] = [
        AgentProfile(
            id: UUID(uuidString: "A6E1C0DE-0001-4000-8000-000000000001")!,
            name: "Coder",
            icon: "chevron.left.forwardslash.chevron.right",
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
            icon: "pencil.and.outline",
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
            icon: "magnifyingglass",
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
            icon: "checkmark.seal",
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
        )
    ]
}
