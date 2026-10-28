import Foundation

/// Switches off vendor background items listed in `LoginItems.Disable`, for the whole Mac: jobs
/// installed in /Library/LaunchDaemons and /Library/LaunchAgents are unloaded, disabled and their
/// plists deleted. Office and OneDrive updates put some back; this runs every time and logs drift.
/// Items embedded in apps (e.g. Teams' agent) are handled per user by `UserLoginItemsModule`.
public struct LoginItemsModule: Module {
    public let id = "login-items"
    public let scope = Scope.device
    public let enforce = Enforce.always

    public init() {}

    public func configHash(_ config: AgentConfig) -> String? {
        guard let c = config.loginItems, !c.disable.isEmpty else { return nil }
        return ConfigHash.of(c)
    }

    public func run(_ ctx: ModuleContext, data: inout [String: String]) throws -> Outcome {
        let labels = (ctx.config.loginItems?.disable ?? []).filter { !LoginItemsConfig.isProtected($0) }
        let fm = FileManager.default
        let consoleUID = ctx.system.consoleUser().flatMap { ctx.shell.run("/usr/bin/id", ["-u", $0]).trimmedOutput.nonEmpty }
        var removed: [String] = []

        for label in labels {
            let daemon = ctx.paths.resolve("/Library/LaunchDaemons/\(label).plist")
            if fm.fileExists(atPath: daemon.path) {
                removed.append(label)
                if !ctx.dryRun {
                    _ = ctx.shell.run("/bin/launchctl", ["bootout", "system/\(label)"])
                    _ = ctx.shell.run("/bin/launchctl", ["disable", "system/\(label)"])   // stays off if reinstalled
                    try fm.removeItem(at: daemon)
                }
            }
            let agent = ctx.paths.resolve("/Library/LaunchAgents/\(label).plist")
            if fm.fileExists(atPath: agent.path) {
                removed.append(label)
                if !ctx.dryRun {
                    if let uid = consoleUID { _ = ctx.shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"]) }
                    try fm.removeItem(at: agent)
                }
            }
        }
        return removed.isEmpty ? .ok("no listed background items installed")
                               : .changed("removed " + Array(Set(removed)).sorted().joined(separator: ", "))
    }
}

/// Per-user half of LoginItems: background agents that live inside an app bundle (registered with
/// SMAppService, e.g. com.microsoft.teams2.agent) can't be deleted, so they're disabled in the
/// user's own launchd domain, which survives app updates.
public struct UserLoginItemsModule: Module {
    public let id = "login-items-user"
    public let scope = Scope.session
    public let enforce = Enforce.always

    public init() {}

    public func configHash(_ config: AgentConfig) -> String? {
        guard let c = config.loginItems, !c.disable.isEmpty else { return nil }
        return ConfigHash.of(c)
    }

    public func run(_ ctx: ModuleContext, data: inout [String: String]) throws -> Outcome {
        let labels = (ctx.config.loginItems?.disable ?? []).filter { !LoginItemsConfig.isProtected($0) }
        let uid = String(getuid())
        let domain = "gui/\(uid)"
        // "disabled services = { "com.x" => disabled ... }"
        let disabledList = ctx.shell.run("/bin/launchctl", ["print-disabled", domain]).stdout
        var disabled: [String] = []
        for label in labels {
            let alreadyOff = disabledList.contains("\"\(label)\" => disabled") || disabledList.contains("\"\(label)\" => true")
            let loaded = ctx.shell.run("/bin/launchctl", ["print", "\(domain)/\(label)"]).succeeded
            guard !alreadyOff || loaded else { continue }
            disabled.append(label)
            if !ctx.dryRun {
                _ = ctx.shell.run("/bin/launchctl", ["disable", "\(domain)/\(label)"])
                _ = ctx.shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
            }
        }
        return disabled.isEmpty ? .ok("background items off") : .changed("disabled " + disabled.joined(separator: ", "))
    }
}
