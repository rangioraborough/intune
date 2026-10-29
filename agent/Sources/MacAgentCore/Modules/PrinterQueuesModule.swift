import Foundation

/// Adds the copier queues with the driver's PPD and seeds the Mac's default printer if it has
/// none. A queue that already points at the right address is never touched, because re-running
/// lpadmin resets its saved options (and users' last-used presets). Replaces ConfigurePrinters.sh step 1.
public struct PrinterQueuesModule: Module {
    public let id = "printer-queues"
    public let scope = Scope.device
    public let enforce = Enforce.always

    public init() {}

    struct HashInput: Encodable {
        let ppd: String; let queues: [PrintersConfig.Queue]; let defaultQueue: String?; let options: [String: String]?
    }

    public func configHash(_ config: AgentConfig) -> String? {
        guard let p = config.printers, !p.queues.isEmpty else { return nil }
        return ConfigHash.of(HashInput(ppd: p.ppd, queues: p.queues, defaultQueue: p.defaultQueue, options: p.options))
    }

    public func run(_ ctx: ModuleContext, data: inout [String: String]) throws -> Outcome {
        guard let cfg = ctx.config.printers else { return .ok("not configured") }
        guard ctx.system.fileExists(cfg.ppd) else {
            return .waiting("printer driver not installed yet (no \((cfg.ppd as NSString).lastPathComponent))")
        }

        var toAdd: [PrintersConfig.Queue] = []
        for q in cfg.queues {
            // "device for Ruru_Copier: lpd://10.69.192.23/" (CUPS often drops the trailing slash)
            let line = ctx.shell.run("/usr/bin/lpstat", ["-v", q.name]).trimmedOutput
            let existing = line.range(of: ": ").map { String(line[$0.upperBound...]) } ?? ""
            if Self.trimSlash(existing) != Self.trimSlash(q.uri) { toAdd.append(q) }
        }

        var changes: [String] = []
        if !toAdd.isEmpty, !ctx.dryRun {
            let ppd = try Self.plainPPD(cfg.ppd, shell: ctx.shell)
            defer { try? FileManager.default.removeItem(at: ppd.deletingLastPathComponent()) }
            var failed: [String] = []
            for q in toAdd {
                let r = ctx.shell.run("/usr/sbin/lpadmin", ["-p", q.name, "-E", "-v", q.uri, "-P", ppd.path,
                                                            "-D", q.description ?? q.name, "-o", "printer-is-shared=false"])
                if r.succeeded { changes.append("added \(q.name)") } else { failed.append("\(q.name): lpadmin exited \(r.exitCode)") }
            }
            if !failed.isEmpty { throw ModuleError((changes + failed).joined(separator: "; ")) }
        } else {
            changes += toAdd.map { "added \($0.name)" }
        }

        // Queue defaults, e.g. Duplex=None. `lpoptions -l` marks the current default with *.
        if let options = cfg.options, !options.isEmpty {
            for q in cfg.queues where !toAdd.contains(where: { $0.name == q.name }) || !ctx.dryRun {
                let listing = ctx.shell.run("/usr/bin/lpoptions", ["-p", q.name, "-l"]).stdout
                for (option, value) in options.sorted(by: { $0.key < $1.key }) {
                    guard Self.currentDefault(of: option, in: listing) != value else { continue }
                    changes.append("\(q.name) \(option)=\(value)")
                    if !ctx.dryRun { try ctx.shell.check("/usr/sbin/lpadmin", ["-p", q.name, "-o", "\(option)-default=\(value)"]) }
                }
            }
        }

        if let def = cfg.defaultQueue, !ctx.shell.run("/usr/bin/lpstat", ["-d"]).stdout.contains(":") {
            changes.append("Mac default printer \(def)")
            if !ctx.dryRun { try ctx.shell.check("/usr/bin/lpoptions", ["-d", def]) }
        }
        return changes.isEmpty ? .ok("\(cfg.queues.count) printers set up") : .changed(changes.joined(separator: ", "))
    }

    static func trimSlash(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }

    /// From `lpoptions -l` output like "Duplex/2-Sided Printing: *DuplexNoTumble None DuplexTumble".
    static func currentDefault(of option: String, in listing: String) -> String? {
        for line in listing.split(separator: "\n") {
            let name = line.split(separator: ":").first.map { String($0.split(separator: "/").first ?? "") }
            guard name == option else { continue }
            return line.split(separator: " ").first(where: { $0.hasPrefix("*") }).map { String($0.dropFirst()) }
        }
        return nil
    }

    /// lpadmin -P wants a plain PPD; drivers often install them gzipped.
    static func plainPPD(_ path: String, shell: CommandRunner) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macagent-ppd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let gz = path.hasSuffix(".gz")
        let copy = dir.appendingPathComponent(gz ? "driver.ppd.gz" : "driver.ppd")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
        if gz { try shell.check("/usr/bin/gunzip", ["-f", copy.path]) }
        return dir.appendingPathComponent("driver.ppd")
    }
}
