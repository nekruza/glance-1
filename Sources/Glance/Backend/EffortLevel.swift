import Foundation

/// How hard the model thinks before answering — the footer's Effort menu.
/// `rawValue` is what the CLIs take: Claude's `effortLevel` setting and
/// Codex's `model_reasoning_effort`. `nil` everywhere means "the CLI's own
/// default", which is not the same as any one level.
///
/// Claude's `max` is deliberately absent: the CLI ignores it when set on a
/// live session (it needs a launch flag), so offering it would be a menu
/// item that silently does nothing.
enum EffortLevel: String, CaseIterable, Identifiable {
    case low, medium, high, xhigh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        }
    }

    var summary: String {
        switch self {
        case .low: return "Fastest, lightest thinking"
        case .medium: return "Balanced speed and depth"
        case .high: return "Thorough reasoning"
        case .xhigh: return "Deepest reasoning, slowest"
        }
    }

    /// Levels worth offering for this provider. For Claude, narrowed to what
    /// the chosen model reports in `supportedEffortLevels`; a model that
    /// explicitly doesn't support effort gets none (no menu).
    static func available(for kind: AskBackendKind, model: ModelOption?) -> [EffortLevel] {
        switch kind {
        case .codex:
            return [.low, .medium, .high]
        case .claude:
            guard model?.supportsEffort != false else { return [] }
            guard let supported = model?.supportedEffortLevels else { return allCases }
            return allCases.filter { supported.contains($0.rawValue) }
        }
    }
}
