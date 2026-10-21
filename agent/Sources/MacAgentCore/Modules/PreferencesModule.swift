import Foundation

/// Sets user preferences from `Preferences`: a list of domains, each with keys to set, an enforce
/// mode and an optional process to restart. Replaces ConfigureFinder.sh and is the generic home for
/// any other per-user `defaults write`.
public struct PreferencesModule: Module {
    public let id = "preferences"
    public let scope = Scope.session
    public let enforce = Enforce.module

    public init() {}

    public func configHash(_ config: AgentConfig) -> String? {
        guard let entries = config.preferences, !entries.isEmpty else { return nil }
        return ConfigHash.of(entries)
    }

    public func run(_ ctx: ModuleContext, data: inout [String: String]) throws -> Outcome {
        let entries = ctx.config.preferences ?? []
        var changed: [String] = []
        var drifted: [String] = []
        var restarts: [String] = []

        for entry in entries {
            let entryHash = ConfigHash.of(entry)
            let appliedKey = "applied.\(entry.domain)"
            let alreadyApplied = data[appliedKey] == entryHash
            if entry.enforceMode == .once, alreadyApplied, !ctx.force { continue }

            var keys: [String] = []
            for key in entry.settings.keys.sorted() {
                let current = ctx.prefs.value(key, domain: entry.domain)
                let desired = PlistMerge.merge(entry.settings[key]!.foundationValue, into: current)
                guard !PlistMerge.equal(current, desired) else { continue }
                keys.append(key)
                if !ctx.dryRun { ctx.prefs.set(key, desired, domain: entry.domain) }
            }

            if !keys.isEmpty {
                if !ctx.dryRun, !ctx.prefs.synchronize(domain: entry.domain) {
                    throw ModuleError("could not save \(entry.domain)")
                }
                let summary = "\(entry.domain) " + keys.joined(separator: " ")
                if alreadyApplied && !ctx.force { drifted.append(summary) } else { changed.append(summary) }
                if let restart = entry.restart, !restarts.contains(restart) { restarts.append(restart) }
            }
            data[appliedKey] = entryHash
        }

        // Forget domains that have been removed from the config, so re-adding one applies it again.
        let domains = Set(entries.map { "applied.\($0.domain)" })
        for key in data.keys where key.hasPrefix("applied.") && !domains.contains(key) { data[key] = nil }

        if !ctx.dryRun {
            for process in restarts { _ = ctx.shell.run("/usr/bin/killall", [process]) }
        }
        if !drifted.isEmpty {
            return .drift("put back " + drifted.joined(separator: "; ")
                          + (changed.isEmpty ? "" : "; set " + changed.joined(separator: "; ")))
        }
        if !changed.isEmpty { return .changed("set " + changed.joined(separator: "; ")) }
        return .ok("preferences as configured")
    }
}
