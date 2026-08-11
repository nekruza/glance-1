import Foundation

/// Resolves what the CLI's model aliases (default/haiku/sonnet/opus) actually
/// map to, so the task model menu can show real names ("Opus 4.8"). Probing
/// requires a real (tiny) generation per alias, so results are cached in
/// UserDefaults keyed by CLI version — re-probed only when the CLI updates.
@MainActor
final class ModelCatalog: ObservableObject {

    static let shared = ModelCatalog()

    /// alias → human name ("sonnet" → "Sonnet 5"). Empty until resolved.
    @Published private(set) var names: [String: String] = [:]

    private static let cacheKey = "models.aliasNames"
    private static let versionKey = "models.cliVersion"
    private var probing = false

    func displayName(for alias: String?) -> String? {
        names[alias ?? "default"]
    }

    static func choices(for provider: AskBackendKind) -> [AutomationModelChoice] {
        AutomationProviderDescriptor(kind: provider, version: "").modelChoices
    }

    static func label(for choice: AutomationModelChoice, provider: AskBackendKind) -> String {
        switch choice {
        case .automatic:
            return "Auto — \(provider.displayName) default"
        case .haiku, .sonnet, .opus:
            return choice.rawValue
        }
    }

    /// UI selection for a persisted model. Unsupported aliases are presented
    /// as automatic without mutating the persisted value.
    static func presentedChoice(for storedModel: String?, provider: AskBackendKind)
        -> AutomationModelChoice {
        guard let storedModel,
              let choice = AutomationModelChoice(rawValue: storedModel),
              choices(for: provider).contains(choice)
        else { return .automatic }
        return choice
    }

    /// Codex currently has no named model menu, so selecting its only visible
    /// choice must retain a Claude alias for a later provider switch.
    static func storedModel(afterSelecting choice: AutomationModelChoice,
                            current: String?, provider: AskBackendKind) -> String? {
        guard provider == .claude else { return current }
        return choice == .automatic ? nil : choice.rawValue
    }

    /// Provider-aware entry point used once AppCoordinator migrates in Task 6.
    func refresh(for provider: AskBackendKind, binaryPath: String, cliVersion: String) {
        guard provider == .claude else { return }
        refresh(binaryPath: binaryPath, cliVersion: cliVersion)
    }

    /// Claude compatibility entry point until AppCoordinator migrates in Task 6.
    func refresh(binaryPath: String, cliVersion: String) {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.versionKey) == cliVersion,
           let cached = defaults.dictionary(forKey: Self.cacheKey) as? [String: String],
           !cached.isEmpty {
            names = cached
            return
        }
        guard !probing else { return }
        probing = true

        Task.detached(priority: .utility) {
            var resolved: [String: String] = [:]
            for alias in ["default", "haiku", "sonnet", "opus"] {
                if let id = Self.probe(binaryPath: binaryPath,
                                       alias: alias == "default" ? nil : alias) {
                    resolved[alias] = Self.prettify(id)
                }
            }
            await MainActor.run { [resolved] in
                guard !resolved.isEmpty else {
                    self.probing = false
                    return
                }
                self.names = resolved
                UserDefaults.standard.set(resolved, forKey: Self.cacheKey)
                UserDefaults.standard.set(cliVersion, forKey: Self.versionKey)
                self.probing = false
            }
        }
    }

    /// One minimal generation; the result JSON's modelUsage names the model id.
    nonisolated private static func probe(binaryPath: String, alias: String?) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        var args = ["-p", "--output-format", "json"]
        if let alias { args += ["--model", alias] }
        args.append("Reply with exactly: ok")
        proc.arguments = args
        proc.currentDirectoryURL = FileManager.default.temporaryDirectory
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = obj["modelUsage"] as? [String: Any]
        else { return nil }
        return usage.keys.first
    }

    /// "claude-opus-4-8" → "Opus 4.8"; "claude-haiku-4-5-20251001" → "Haiku 4.5".
    nonisolated static func prettify(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        // Drop a trailing date stamp (8 digits).
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        let family = parts.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? id
        let version = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return version.isEmpty ? family : "\(family) \(version)"
    }
}
