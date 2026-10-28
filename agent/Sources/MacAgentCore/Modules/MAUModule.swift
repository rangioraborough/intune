import Foundation

/// Keeps Microsoft AutoUpdate off. Office updates put its LaunchAgent back; this runs every time
/// and reports drift when it had to remove it again. Replaces DisableMAU.sh.
public struct MAUModule: Module {
    public let id = "mau-disable"
    public let scope = Scope.device
    public let enforce = Enforce.always

    public init() {}

    static let prefs = "/Library/Preferences/com.microsoft.autoupdate2"
    static let keys = ["EnableAutoUpdate", "EnableCheckForUpdates", "StartDaemonOnAppLaunch"]
    static let launchAgent = "/Library/LaunchAgents/com.microsoft.update.agent.plist"
    static let cache = "/Library/Caches/com.microsoft.autoupdate.fba"

    public func configHash(_ config: AgentConfig) -> String? {
        guard let c = config.microsoftAutoUpdate, c.disable else { return nil }
        return ConfigHash.of(c)
    }

    public func run(_ ctx: ModuleContext, data: inout [String: String]) throws -> Outcome {
        var changes: [String] = []
        for key in Self.keys where ctx.shell.run("/usr/bin/defaults", ["read", Self.prefs, key]).trimmedOutput != "0" {
            changes.append(key)
            if !ctx.dryRun { try ctx.shell.check("/usr/bin/defaults", ["write", Self.prefs, key, "-bool", "false"]) }
        }

        let agent = ctx.paths.resolve(Self.launchAgent)
        if FileManager.default.fileExists(atPath: agent.path) {
            changes.append("removed update LaunchAgent")
            if !ctx.dryRun {
                if let user = ctx.system.consoleUser(),
                   let uid = ctx.shell.run("/usr/bin/id", ["-u", user]).trimmedOutput.nonEmpty {
                    _ = ctx.shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/com.microsoft.update.agent"])
                }
                try FileManager.default.removeItem(at: agent)
            }
        }

        let cache = ctx.paths.resolve(Self.cache)
        if FileManager.default.fileExists(atPath: cache.path) {
            changes.append("cleared update cache")
            if !ctx.dryRun { try? FileManager.default.removeItem(at: cache) }
        }
        return changes.isEmpty ? .ok("AutoUpdate off") : .changed(changes.joined(separator: ", "))
    }
}

extension String {
    public var nonEmpty: String? { isEmpty ? nil : self }
}
