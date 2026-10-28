import Foundation

/// Sets each local user's account picture once, from the site resources. Covers users who
/// haven't logged in yet. Replaces SetUserAvatar.sh (console user only).
public struct AvatarModule: Module {
    public let id = "avatar"
    public let scope = Scope.device
    public let enforce = Enforce.module

    let directory: DirectoryService?

    public init(directory: DirectoryService? = nil) { self.directory = directory }

    public func configHash(_ config: AgentConfig) -> String? { config.avatar.map(ConfigHash.of) }

    public func run(_ ctx: ModuleContext, data: inout [String: String]) throws -> Outcome {
        guard let cfg = ctx.config.avatar else { return .ok("not configured") }
        let dir = directory ?? LiveDirectory(shell: ctx.shell)
        let excluded = ctx.config.allExcludedUsers
        var set: [String] = []
        var missingFiles: Set<String> = []

        for user in try dir.localUsers() {
            guard let image = cfg.users?[user.name] ?? (excluded.contains(user.name) ? nil : cfg.defaultImage) else { continue }
            let key = "set.\(user.name)"
            if data[key] == image, !ctx.force { continue }   // once per user per picture
            let path = ctx.paths.siteResources.appendingPathComponent(image).path
            guard ctx.system.fileExists(path) else { missingFiles.insert(image); continue }
            if dir.picture(user.name) != path, !ctx.dryRun { try dir.setPicture(user.name, path: path) }
            data[key] = image
            set.append(user.name)
        }

        if !missingFiles.isEmpty {
            return .waiting("\(missingFiles.sorted().joined(separator: ", ")) not installed yet (site resources package)")
        }
        return set.isEmpty ? .ok("account pictures already set") : .changed("picture set for " + set.joined(separator: ", "))
    }
}
