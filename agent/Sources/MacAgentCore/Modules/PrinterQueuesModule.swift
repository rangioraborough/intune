import Foundation

/// Adds the copier queues with the driver's PPD and seeds the Mac's default printer if it has
/// none. A queue that already points at the right address is never touched, because re-running
/// lpadmin resets its saved options (and users' last-used presets). Replaces ConfigurePrinters.sh step 1.
public struct PrinterQueuesModule: Module {
    public let id = "printer-queues"
    public let scope = Scope.device
    public let enforce = Enforce.always

    public init() {}

    struct HashInput: Encodable { let ppd: String; let queues: [PrintersConfig.Queue]; let defaultQueue: String? }

    public func configHash(_ config: AgentConfig) -> String? {
        guard let p = config.printers, !p.queues.isEmpty else { return nil }
        return ConfigHash.of(HashInput(ppd: p.ppd, queues: p.queues, defaultQueue: p.defaultQueue))
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

        if let def = cfg.defaultQueue, !ctx.shell.run("/usr/bin/lpstat", ["-d"]).stdout.contains(":") {
            changes.append("Mac default printer \(def)")
            if !ctx.dryRun { try ctx.shell.check("/usr/bin/lpoptions", ["-d", def]) }
        }
        return changes.isEmpty ? .ok("\(cfg.queues.count) printers set up") : .changed(changes.joined(separator: ", "))
    }

    static func trimSlash(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }

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
