import Foundation

/// Gives each user the school's print presets (once) and seeds their default printer if they
/// have none. Runs in the session, so new users get it at first login without a User Template.
public struct PrinterPresetsModule: Module {
    public let id = "printer-presets"
    public let scope = Scope.session
    public let enforce = Enforce.once

    public init() {}

    struct HashInput: Encodable { let presets: String?; let defaultQueue: String? }

    public func configHash(_ config: AgentConfig) -> String? {
        guard let p = config.printers, p.presets != nil || p.defaultQueue != nil else { return nil }
        return ConfigHash.of(HashInput(presets: p.presets, defaultQueue: p.defaultQueue))
    }

    public func run(_ ctx: ModuleContext, data: inout [String: String]) throws -> Outcome {
        guard let cfg = ctx.config.printers else { return .ok("not configured") }
        var done: [String] = []

        if let presets = cfg.presets {
            let file = ctx.paths.siteResources.appendingPathComponent(presets)
            guard let raw = try? Data(contentsOf: file) else {
                return .waiting("\(presets) isn't installed yet (site resources package)")
            }
            guard let template = try? PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any] else {
                throw ModuleError("\(presets) is not a valid plist")
            }
            let existing = Set(ctx.prefs.keys(domain: PrinterDetails.presetsDomain))
            let missing = template.keys.filter { !existing.contains($0) }.sorted()
            if !missing.isEmpty {
                if !ctx.dryRun {
                    for key in missing { ctx.prefs.set(key, template[key], domain: PrinterDetails.presetsDomain) }
                    guard ctx.prefs.synchronize(domain: PrinterDetails.presetsDomain) else {
                        throw ModuleError("could not save print presets")
                    }
                }
                done.append("added \(missing.count) preset\(missing.count == 1 ? "" : "s")")
            }
        }

        if let queue = cfg.defaultQueue {
            guard ctx.shell.run("/usr/bin/lpstat", ["-p", queue]).succeeded else {
                return .waiting("printer \(queue) isn't set up yet")
            }
            // lpstat -d prints "system default destination: X" or "no system default destination".
            if !ctx.shell.run("/usr/bin/lpstat", ["-d"]).stdout.contains(":") {
                if !ctx.dryRun { try ctx.shell.check("/usr/bin/lpoptions", ["-d", queue]) }
                done.append("default printer \(queue)")
            }
        }
        return done.isEmpty ? .ok("presets and default printer already set") : .changed(done.joined(separator: ", "))
    }
}
