import Foundation

/// Names the Mac from a template, e.g. "{model}-{user}" → "MBA-Annabellesimpson".
/// The user is the first real user seen at the console; after that the name is locked to them,
/// so shared Macs don't flip names. `macagent state reset device-name` re-picks.
public struct DeviceNameModule: Module {
    public let id = "device-name"
    public let scope = Scope.device
    public let enforce = Enforce.always

    public init() {}

    static let defaultModelCodes: [String: String] = [
        "MacBook Air": "MBA",
        "MacBook Pro": "MBP",
        "MacBook": "MB",
        "iMac": "iMac",
        "Mac Pro": "PRO",
        "Mac mini": "MacMini",
        "Mac Studio": "MS",
        "Apple Virtual Machine": "VM",
    ]

    /// Bump when the way names are built changes, so existing Macs are renamed as "changed", not drift.
    /// 2: {user} comes from the account's full name ("KellyTaylor"); Mac mini is "MacMini".
    static let scheme = 2

    struct HashInput: Encodable {
        let scheme: Int
        let template: String
        let modelCodes: [String: String]
        let excluded: [String]
    }

    public func configHash(_ config: AgentConfig) -> String? {
        guard let dn = config.deviceName, dn.enabled ?? true else { return nil }
        return ConfigHash.of(HashInput(scheme: Self.scheme, template: dn.resolvedTemplate, modelCodes: dn.modelCodes ?? [:],
                                       excluded: config.allExcludedUsers.sorted()))
    }

    public func run(_ ctx: ModuleContext, data: inout [String: String]) throws -> Outcome {
        guard let dn = ctx.config.deviceName else { return .ok("not configured") }
        let template = dn.resolvedTemplate
        let excluded = ctx.config.allExcludedUsers

        var user = ""
        if template.contains("{user}") || template.contains("{username}") {
            if let locked = data["user"], !excluded.contains(locked) {
                user = locked
            } else if let console = ctx.system.consoleUser(), !excluded.contains(console) {
                user = console
                data["user"] = console
            } else {
                data["user"] = nil
                return .waiting("no eligible user logged in yet to name the Mac after")
            }
        }

        let hw = try ctx.system.hardware()
        let name = Self.render(template: template,
                               model: Self.modelCode(for: hw.modelName, overrides: dn.modelCodes ?? [:]),
                               username: user, fullName: user.isEmpty ? nil : ctx.system.fullName(of: user),
                               serial: hw.serial)
        let hostName = Self.hostSafe(name)
        guard !hostName.isEmpty else { throw ModuleError("template \"\(template)\" produced an empty name") }

        let desired = ["ComputerName": name, "LocalHostName": hostName, "HostName": hostName]
        var changes: [String] = []
        for key in ["ComputerName", "LocalHostName", "HostName"] {
            let current = ctx.shell.run("/usr/sbin/scutil", ["--get", key]).trimmedOutput
            guard current != desired[key] else { continue }
            changes.append("\(key) \"\(current)\" → \"\(desired[key]!)\"")
            if !ctx.dryRun { try ctx.shell.check("/usr/sbin/scutil", ["--set", key, desired[key]!]) }
        }
        return changes.isEmpty ? .ok("named \(name)") : .changed(changes.joined(separator: ", "))
    }

    /// Longest matching prefix wins, so "MacBook Air" beats "MacBook". Unknown models get the
    /// first four characters with spaces removed, as DeviceRename.sh did.
    static func modelCode(for modelName: String, overrides: [String: String]) -> String {
        let table = defaultModelCodes.merging(overrides) { _, new in new }
        if let match = table.keys.filter({ modelName.hasPrefix($0) }).max(by: { $0.count < $1.count }) {
            return table[match]!
        }
        return String(modelName.replacingOccurrences(of: " ", with: "").prefix(4))
    }

    /// "Kelly Taylor" → "KellyTaylor", "anna.simpson" → "AnnaSimpson", "Mary-Jane O'Neil" → "MaryJaneO'Neil".
    /// Inner capitals are kept ("McDonald" stays "McDonald").
    static func formatUser(_ name: String) -> String {
        name.split(whereSeparator: { $0 == "." || $0 == " " || $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()
    }

    /// {user} is the account's full name when it has one, else the username, both CamelCased.
    static func render(template: String, model: String, username: String, fullName: String? = nil,
                       serial: String) -> String {
        template
            .replacingOccurrences(of: "{model}", with: model)
            .replacingOccurrences(of: "{user}", with: formatUser(fullName ?? username))
            .replacingOccurrences(of: "{username}", with: username)
            .replacingOccurrences(of: "{serial}", with: serial)
    }

    /// LocalHostName/HostName allow only letters, digits and hyphens, max 63 characters.
    static func hostSafe(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let mapped = String(name.map { allowed.contains($0) ? $0 : "-" })
        let collapsed = mapped.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return String(collapsed.prefix(63))
    }
}
