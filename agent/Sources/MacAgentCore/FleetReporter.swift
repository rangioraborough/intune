import Foundation

/// Requests from the console that runs act on: "re-apply module X" (anything asked for after the
/// module last ran is forced). Written by the root reporter, read by device and session runs.
public struct FleetRequests: Codable, Equatable, Sendable {
    public var reapply: [String: Date] = [:]
    /// School copiers removed from this Mac from the console; optional so older files still load.
    public var removedPrinters: [String]?
    /// Optional copiers added to this Mac from the console.
    public var addedPrinters: [String]?

    public init(reapply: [String: Date] = [:], removedPrinters: [String]? = nil, addedPrinters: [String]? = nil) {
        self.reapply = reapply
        self.removedPrinters = removedPrinters
        self.addedPrinters = addedPrinters
    }

    public var removed: Set<String> { Set(removedPrinters ?? []) }
    public var added: Set<String> { Set(addedPrinters ?? []) }

    /// The configured copiers this Mac should have.
    public func wanted(_ queues: [PrintersConfig.Queue]) -> [PrintersConfig.Queue] {
        queues.filter { !removed.contains($0.name) && ($0.isOptional != true || added.contains($0.name)) }
    }

    public static func url(_ paths: Paths) -> URL {
        paths.configCache.deletingLastPathComponent().appendingPathComponent("requests.json")
    }

    public static func load(_ paths: Paths) -> FleetRequests {
        (try? Data(contentsOf: url(paths))).flatMap { try? FleetWire.decoder().decode(FleetRequests.self, from: $0) }
            ?? FleetRequests()
    }

    public func save(_ paths: Paths) throws {
        try FleetWire.encoder().encode(self).write(to: Self.url(paths), options: .atomic)
    }

    /// Modules to force in this run: requested after they last ran here.
    public func modulesToForce(state: StateStore, subject: String) -> Set<String> {
        Set(reapply.compactMap { module, requested in
            guard let last = state.get(module: module, subject: subject)?.lastRun else { return module }
            return requested > last ? module : nil
        })
    }
}

/// Builds and sends this Mac's report, and carries out signed actions that come back.
public struct FleetReporter: Sendable {
    public var console: ConsoleConfig
    public var paths: Paths
    public var shell: CommandRunner
    public var system: SystemInfo

    public init(console: ConsoleConfig, paths: Paths, shell: CommandRunner, system: SystemInfo) {
        self.console = console
        self.paths = paths
        self.shell = shell
        self.system = system
    }

    struct Journal: Codable {
        var done: [String] = []
        var pending: [FleetReport.ActionResult] = []
    }

    var journalURL: URL { paths.configCache.deletingLastPathComponent().appendingPathComponent("actions.json") }

    func loadJournal() -> Journal {
        (try? Data(contentsOf: journalURL)).flatMap { try? FleetWire.decoder().decode(Journal.self, from: $0) } ?? Journal()
    }

    func saveJournal(_ j: Journal) {
        try? FleetWire.encoder().encode(j).write(to: journalURL, options: .atomic)
    }

    public func buildReport(configVersion: Int?, deviceState: [ModuleState], userStates: [ModuleState]) -> FleetReport {
        let hw = try? system.hardware()
        let states = (deviceState + userStates).map {
            FleetReport.State(subject: $0.subject, module: $0.module, result: $0.result.rawValue, detail: $0.detail, lastRun: $0.lastRun)
        }
        let ip = ["en0", "en1"].lazy.map { shell.run("/usr/sbin/ipconfig", ["getifaddr", $0]).trimmedOutput }.first { !$0.isEmpty }
        return FleetReport(
            serial: hw?.serial ?? "unknown",
            computerName: shell.run("/usr/sbin/scutil", ["--get", "ComputerName"]).trimmedOutput,
            model: hw?.modelName ?? "Mac",
            macOS: shell.run("/usr/bin/sw_vers", ["-productVersion"]).trimmedOutput,
            agentVersion: AgentVersion.current,
            consoleUser: system.consoleUser(),
            officeVersion: system.appVersion("/Applications/Microsoft Word.app"),
            configVersion: configVersion,
            ipAddress: ip,
            sentAt: Date(),
            states: states,
            actionResults: loadJournal().pending,
            printers: installedPrinters(),
            removedPrinters: FleetRequests.load(paths).removedPrinters ?? [])
    }

    func installedPrinters() -> [FleetReport.Printer] {
        Self.parsePrinters(devices: shell.run("/usr/bin/lpstat", ["-v"]).stdout,
                           defaultLine: shell.run("/usr/bin/lpstat", ["-d"]).stdout,
                           details: shell.run("/usr/bin/lpstat", ["-l", "-p"]).stdout)
    }

    /// From `lpstat -v` ("device for Ruru_Copier: lpd://10.69.192.23/"), `lpstat -d`
    /// ("system default destination: Ruru_Copier") and `lpstat -l -p` ("\tDescription: Ruru Copier").
    static func parsePrinters(devices: String, defaultLine: String, details: String) -> [FleetReport.Printer] {
        let def = defaultLine.range(of: "destination: ").map {
            String(defaultLine[$0.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var descriptions: [String: String] = [:]
        var current: String?
        for line in details.split(separator: "\n") {
            if line.hasPrefix("printer ") {
                current = line.split(separator: " ").dropFirst().first.map(String.init)
            } else if let current, let r = line.range(of: "Description: ") {
                descriptions[current] = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return devices.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("device for "), let r = line.range(of: ": ") else { return nil }
            let name = String(line[line.index(line.startIndex, offsetBy: 11)..<r.lowerBound])
            return FleetReport.Printer(name: name, uri: String(line[r.upperBound...]),
                                       description: descriptions[name], isDefault: name == def)
        }.sorted { $0.name < $1.name }
    }

    /// CUPS queue names: nothing that could be read as an option or a path.
    static func isValidQueueName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && name.count <= 127
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    /// Run the printer module now (adds a queue, sets the default). The console then gets a fresh report.
    func runPrinterQueues() {
        _ = shell.run(AgentIdentity.cliPath, ["run", "--scope", "device", "--module", "printer-queues"])
    }

    func addPrinter(_ name: String) throws -> String {
        guard case .loaded(let config, _) = ConfigLoader(paths: paths).load(updateCache: false),
              let queue = config.printers?.queues.first(where: { $0.name == name }) else {
            throw ModuleError("\(name) isn't one of the school's copiers in this Mac's config")
        }
        var requests = FleetRequests.load(paths)
        requests.removedPrinters = (requests.removedPrinters ?? []).filter { $0 != name }
        if queue.isOptional == true, !requests.added.contains(name) { requests.addedPrinters = (requests.addedPrinters ?? []) + [name] }
        try requests.save(paths)
        runPrinterQueues()
        return "added \(name)"
    }

    func removePrinter(_ name: String) throws -> String {
        guard Self.isValidQueueName(name) else { throw ModuleError("\"\(name)\" isn't a valid printer name") }
        // Remember school copiers first, so the agent can't re-add one half way through.
        if case .loaded(let config, _) = ConfigLoader(paths: paths).load(updateCache: false),
           let queue = config.printers?.queues.first(where: { $0.name == name }) {
            var requests = FleetRequests.load(paths)
            if queue.isOptional == true {
                requests.addedPrinters = (requests.addedPrinters ?? []).filter { $0 != name }
            } else if !requests.removed.contains(name) {
                requests.removedPrinters = (requests.removedPrinters ?? []) + [name]
            }
            try requests.save(paths)
        }
        guard shell.run("/usr/bin/lpstat", ["-v", name]).succeeded else { return "\(name) was already gone" }
        try shell.check("/usr/sbin/lpadmin", ["-x", name])
        runPrinterQueues()   // picks a new default if that was the default
        return "removed \(name)"
    }

    /// POST the report; returns the console's response. Throws if the console can't be reached.
    public func send(_ report: FleetReport) throws -> FleetResponse {
        guard let base = URL(string: console.url) else { throw ModuleError("Console URL is invalid") }
        let body = try FleetWire.encoder().encode(report)
        var req = URLRequest(url: base.appendingPathComponent("api/report"), timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(FleetWire.sign(body, fleetKey: console.fleetKey), forHTTPHeaderField: FleetWire.signatureHeader)

        final class Box: @unchecked Sendable { var data: Data?; var status = 0; var error: Error? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, response, error in
            box.data = data
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            box.error = error
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 20)
        if let error = box.error { throw ModuleError("console unreachable: \(error.localizedDescription)") }
        guard box.status == 200, let data = box.data else { throw ModuleError("console replied \(box.status)") }

        // Delivered: the results we sent no longer need sending.
        var j = loadJournal()
        j.pending.removeAll()
        saveJournal(j)
        return (try? FleetWire.decoder().decode(FleetResponse.self, from: data)) ?? FleetResponse(actions: [])
    }

    /// Long-poll the console: it answers as soon as there's a request for this Mac, or with nothing
    /// after about a minute. Lets the console's buttons take effect straight away without the Mac
    /// listening on the network.
    public func wait(serial: String) throws -> [FleetAction] {
        let path = FleetWire.waitPath(serial)
        guard let url = URL(string: console.url + path) else { throw ModuleError("Console URL is invalid") }
        var req = URLRequest(url: url, timeoutInterval: 90)
        req.setValue(FleetWire.sign(Data(path.utf8), fleetKey: console.fleetKey), forHTTPHeaderField: FleetWire.signatureHeader)
        final class Box: @unchecked Sendable { var data: Data?; var status = 0; var error: Error? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, response, error in
            box.data = data
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            box.error = error
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 95)
        if let error = box.error { throw ModuleError("console unreachable: \(error.localizedDescription)") }
        guard box.status == 200, let data = box.data else { throw ModuleError("console replied \(box.status)") }
        return ((try? FleetWire.decoder().decode(FleetResponse.self, from: data)) ?? FleetResponse(actions: [])).actions
    }

    /// Verify and carry out actions. Unsigned, foreign, expired or repeated ones are refused.
    /// Results go out with the next report.
    @discardableResult
    public func handle(_ actions: [FleetAction], serial: String, now: Date = Date()) -> [FleetReport.ActionResult] {
        var j = loadJournal()
        var results: [FleetReport.ActionResult] = []
        for action in actions where !j.done.contains(action.id) {
            let result: FleetReport.ActionResult
            do {
                try action.verify(publicKey: console.publicKey, serial: serial, now: now)
                result = FleetReport.ActionResult(id: action.id, ok: true, detail: try perform(action, now: now))
            } catch let rejection as FleetAction.Rejection {
                result = FleetReport.ActionResult(id: action.id, ok: false, detail: "refused: \(rejection)")
            } catch {
                result = FleetReport.ActionResult(id: action.id, ok: false, detail: (error as? ModuleError)?.message ?? "\(error)")
            }
            results.append(result)
            j.done.append(action.id)
        }
        j.done = Array(j.done.suffix(200))
        j.pending += results
        saveJournal(j)
        return results
    }

    func perform(_ action: FleetAction, now: Date) throws -> String {
        switch action.kind {
        case .run:
            try requestDeviceRun()
            kickstartSession()
            return "check started"
        case .install:
            return try install(action)
        case .addPrinter:
            return try addPrinter(action.printer ?? "")
        case .removePrinter:
            return try removePrinter(action.printer ?? "")
        case .reapply:
            guard let module = action.module, ModuleRegistry.all.contains(where: { $0.id == module }) else {
                throw ModuleError("unknown module \(action.module ?? "(none)")")
            }
            var requests = FleetRequests.load(paths)
            requests.reapply[module] = now
            try requests.save(paths)
            try requestDeviceRun()
            kickstartSession()
            return "re-applying \(module)"
        }
    }

    /// Download from the console, check the SHA-256, then install. Packages install from a one-off
    /// launchd job, not from this process: the agent's own installer stops the agent's jobs, which
    /// would otherwise kill the install half way.
    func install(_ action: FleetAction) throws -> String {
        guard let target = action.target, let sha = action.sha256?.lowercased(), sha.count == 64,
              sha.allSatisfy(\.isHexDigit) else { throw ModuleError("install request is missing its file details") }
        let data = try download(sha)
        guard FleetWire.sha256(data) == sha else { throw ModuleError("download doesn't match the requested file") }
        let support = paths.configCache.deletingLastPathComponent()

        if target == .config {
            guard case .success(let config) = ConfigLoader.decode(data: data, source: "console config") else {
                throw ModuleError("the console's config isn't valid; not applied")
            }
            try data.write(to: paths.configCache, options: .atomic)
            try requestDeviceRun()
            kickstartSession()
            return "config version \(config.configVersion) applied"
        }

        let pkg = URL(fileURLWithPath: "/private/var/tmp/macagent-\(target.rawValue)-\(sha.prefix(12)).pkg")
        try data.write(to: pkg, options: .atomic)
        let label = "nz.co.myers.macagent.updater"
        let plist = support.appendingPathComponent("updater.plist")
        let script = "sleep 3; /usr/sbin/installer -pkg '\(pkg.path)' -target / >> /Library/Logs/MacAgent/update.log 2>&1; "
            + "rm -f '\(pkg.path)' '\(plist.path)'; /bin/launchctl remove \(label)"
        let job: [String: Any] = ["Label": label, "ProgramArguments": ["/bin/sh", "-c", script], "RunAtLoad": true]
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist)
        _ = shell.run("/bin/launchctl", ["bootout", "system/\(label)"])   // a previous one, if any
        try shell.check("/bin/launchctl", ["bootstrap", "system", plist.path])
        return "installing \(target.rawValue) package"
    }

    func download(_ sha: String) throws -> Data {
        guard let url = URL(string: console.url + FleetWire.filePath(sha)) else { throw ModuleError("Console URL is invalid") }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.setValue(FleetWire.sign(Data(FleetWire.filePath(sha).utf8), fleetKey: console.fleetKey),
                     forHTTPHeaderField: FleetWire.signatureHeader)
        final class Box: @unchecked Sendable { var data: Data?; var status = 0 }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, response, _ in
            box.data = data
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 180)
        guard box.status == 200, let data = box.data else { throw ModuleError("couldn't download from the console (\(box.status))") }
        return data
    }

    func requestDeviceRun() throws {
        let dir = paths.configCache.deletingLastPathComponent().appendingPathComponent("Trigger")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(ISO8601DateFormatter().string(from: Date()).utf8).write(to: dir.appendingPathComponent("console"))
    }

    func kickstartSession() {
        guard let user = system.consoleUser(),
              let uid = shell.run("/usr/bin/id", ["-u", user]).trimmedOutput.nonEmpty else { return }
        _ = shell.run("/bin/launchctl", ["kickstart", "gui/\(uid)/\(AgentIdentity.sessionLabel)"])
    }
}
