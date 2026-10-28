import Foundation

/// Keeps the IT admin account present, an admin, hidden, and on the password whose hash is in
/// `AdminAccount.PasswordHash`. Replaces CreateAdminAccount.sh, which left it with a blank password.
public struct AdminAccountModule: Module {
    public let id = "admin-account"
    public let scope = Scope.device
    public let enforce = Enforce.always

    let directory: DirectoryService?

    public init(directory: DirectoryService? = nil) { self.directory = directory }

    public func configHash(_ config: AgentConfig) -> String? {
        config.adminAccount.map(ConfigHash.of)
    }

    public func run(_ ctx: ModuleContext, data: inout [String: String]) throws -> Outcome {
        guard let cfg = ctx.config.adminAccount, let hash = PasswordHash(string: cfg.passwordHash) else {
            return .ok("not configured")
        }
        let dir = directory ?? LiveDirectory(shell: ctx.shell)
        let name = cfg.username
        var changes: [String] = []

        if !dir.userExists(name) {
            changes.append("created \(name)")
            if ctx.dryRun { return .changed(changes.joined(separator: ", ")) }
            try dir.createAdmin(name, fullName: cfg.fullName ?? name)
        }

        let current = dir.shadowHashData(name).flatMap { PasswordHash(shadowHashData: $0) }
        if current != hash {
            // Rewriting the hash of an account with a Secure Token would desync its FileVault and
            // keychain password. Never do that; say what's needed instead.
            if dir.hasSecureToken(name) {
                throw ModuleError("\(name) has a Secure Token, so its password can't be set from a hash; "
                                  + "reset it once with sysadminctl -resetPasswordFor \(name)")
            }
            changes.append("set password")
            if !ctx.dryRun { try dir.setShadowHashData(name, hash.shadowHashData) }
        }

        if !dir.isAdmin(name) {
            changes.append("made admin")
            if !ctx.dryRun { try dir.makeAdmin(name) }
        }

        let wantHidden = cfg.hidden ?? true
        if dir.isHidden(name) != wantHidden {
            changes.append(wantHidden ? "hidden" : "shown on login window")
            if !ctx.dryRun { try dir.setHidden(name, wantHidden) }
        }

        // Old admin accounts this one replaces. Never the logged-in user or one holding a Secure
        // Token (deleting that could leave FileVault without an unlock account).
        for old in cfg.removeAccounts ?? [] where old != name && dir.userExists(old) {
            if ctx.system.consoleUser() == old {
                throw ModuleError("\(old) is logged in, so it wasn't removed; it will be next time")
            }
            if dir.hasSecureToken(old) {
                throw ModuleError("\(old) has a Secure Token, so it wasn't removed automatically; remove it by hand")
            }
            changes.append("removed old account \(old)")
            if !ctx.dryRun { try dir.deleteUser(old) }
        }

        return changes.isEmpty ? .ok("\(name) present, admin, password as configured")
                               : .changed("\(name): " + changes.joined(separator: ", "))
    }
}
