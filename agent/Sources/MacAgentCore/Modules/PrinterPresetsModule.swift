import Foundation

/// Gives each user the school's print presets (once) and seeds their default printer if they
/// have none. Runs in the session, so new users get it at first login without a User Template.
public struct PrinterPresetsModule: Module {
    public let id = "printer-presets"
    public let scope = Scope.session
    public let enforce = Enforce.once

    public init() {}

    /// Bump to make every user's presets re-apply once. 2: the print dialog had rebuilt "Default
    /// Settings" / "Last Used Settings" as two-sided from the queue PPD before its default was fixed.
    static let scheme = 2

    struct HashInput: Encodable {
        let scheme: Int; let presets: String?; let defaultQueue: String?; let presetSettings: [String: PlistValue]?
    }

    public func configHash(_ config: AgentConfig) -> String? {
        guard let p = config.printers, p.presets != nil || p.defaultQueue != nil || p.presetSettings != nil else { return nil }
        return ConfigHash.of(HashInput(scheme: Self.scheme, presets: p.presets, defaultQueue: p.defaultQueue,
                                       presetSettings: p.presetSettings))
    }

    /// Write `settings` into every preset's settings dict and each printer's last-used settings.
    static func applySettings(_ settings: [String: PlistValue], prefs: PreferencesStore, perPrinter: [String],
                              dryRun: Bool) throws -> Int {
        let want = settings.mapValues(\.foundationValue)
        var updated = 0
        for preset in prefs.keys(domain: PrinterDetails.presetsDomain) {
            guard var dict = prefs.value(preset, domain: PrinterDetails.presetsDomain) as? [String: Any],
                  var inner = dict[PrinterDetails.settingsKey] as? [String: Any] else { continue }
            let before = inner as NSDictionary
            for (k, v) in want { inner[k] = v }
            guard !before.isEqual(to: inner) else { continue }
            updated += 1
            dict[PrinterDetails.settingsKey] = inner
            if !dryRun { prefs.set(preset, dict as NSDictionary, domain: PrinterDetails.presetsDomain) }
        }
        if updated > 0, !dryRun, !prefs.synchronize(domain: PrinterDetails.presetsDomain) {
            throw ModuleError("could not save print presets")
        }
        for domain in perPrinter {
            guard var last = prefs.value(PrinterDetails.lastUsedKey, domain: domain) as? [String: Any] else { continue }
            let before = last as NSDictionary
            for (k, v) in want { last[k] = v }
            guard !before.isEqual(to: last) else { continue }
            updated += 1
            if !dryRun {
                prefs.set(PrinterDetails.lastUsedKey, last as NSDictionary, domain: domain)
                _ = prefs.synchronize(domain: domain)
            }
        }
        return updated
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

        if let settings = cfg.presetSettings, !settings.isEmpty {
            let n = try Self.applySettings(settings, prefs: ctx.prefs, perPrinter: PrinterDetails.perPrinterDomains(),
                                           dryRun: ctx.dryRun)
            if n > 0 { done.append("updated \(n) preset\(n == 1 ? "" : "s") (\(settings.keys.sorted().joined(separator: ", ")))") }
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
