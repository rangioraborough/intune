import Foundation
import MacAgentCore

let usage = """
    macagent \(AgentVersion.current)

    usage:
      macagent run --scope device|session [--module ID] [--force] [--dry-run] [--config PLIST]
      macagent status
      macagent config [--config PLIST]       validate and print the config the agent would use
      macagent state reset [ID] [--scope device|session]
      macagent hash-password                 make AdminAccount.PasswordHash for the Intune config
      macagent report                        send status to the console now and act on its requests (root)
      macagent desktop                       this user's wallpaper and default browser (run as the user)
      macagent version

    The device scope must run as root. launchd runs it at boot, every 4 hours and whenever the
    Intune config profile changes; the session scope runs at every login as that user.
    """

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("macagent: \(message)\n".utf8))
    exit(code)
}

/// Minimal flag parsing: `--name value` and bare `--flag`. No dependencies to sign or audit.
struct Args {
    var positional: [String] = []
    var flags: [String: String] = [:]

    init(_ argv: [String], valued: Set<String>) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if valued.contains(name) {
                    guard i + 1 < argv.count else { fail("--\(name) needs a value") }
                    flags[name] = argv[i + 1]
                    i += 1
                } else {
                    flags[name] = ""
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func has(_ name: String) -> Bool { flags[name] != nil }
}

func scopeArg(_ args: Args, default def: Scope) -> Scope {
    guard let raw = args.flags["scope"] else { return def }
    guard let scope = Scope(rawValue: raw) else { fail("unknown scope \(raw); use device or session") }
    return scope
}

func paths(for scope: Scope) -> Paths {
    switch scope {
    case .device: return .device()
    case .session: return .session(home: FileManager.default.homeDirectoryForCurrentUser)
    }
}

func requireRootIfDevice(_ scope: Scope) {
    if scope == .device && getuid() != 0 { fail("the device scope must run as root (try sudo)") }
}

func loadConfig(_ args: Args, paths: Paths, updateCache: Bool) -> ConfigLoadResult {
    if let override = args.flags["config"] {
        switch ConfigLoader.decode(contentsOf: URL(fileURLWithPath: override)) {
        case .success(let c): return .loaded(c, .managed)
        case .failure(let e): return .unavailable(reason: e.message)
        }
    }
    return ConfigLoader(paths: paths).load(updateCache: updateCache)
}

/// Build this Mac's report (device + every user's state), send it, act on signed actions in the reply.
func sendReport(console: ConsoleConfig, configVersion: Int?, verbose: Bool = false) {
    let shell = SystemCommandRunner()
    let reporter = FleetReporter(console: console, paths: .device(), shell: shell, system: LiveSystemInfo(shell: shell))
    let device = (try? StateStore(url: Paths.device().stateDB, readOnly: true))?.all() ?? []
    var users: [ModuleState] = []
    for user in ((try? FileManager.default.contentsOfDirectory(atPath: "/Users")) ?? []) where !user.hasPrefix(".") {
        let db = Paths.session(home: URL(fileURLWithPath: "/Users/\(user)")).stateDB
        if let store = try? StateStore(url: db, readOnly: true) { users += store.all() }
    }
    let report = reporter.buildReport(configVersion: configVersion, deviceState: device, userStates: users)
    do {
        let response = try reporter.send(report)
        let results = reporter.handle(response.actions, serial: report.serial)
        if verbose {
            print("reported to \(console.url)")
            for r in results { print("action \(r.id): \(r.ok ? "ok" : "failed") - \(r.detail)") }
        }
    } catch {
        if verbose { print("could not report: \(error)") }
    }
}

let argv = Array(CommandLine.arguments.dropFirst())
let command = argv.first ?? "help"
let args = Args(Array(argv.dropFirst()), valued: ["scope", "module", "config"])
let shell = SystemCommandRunner()

switch command {
case "run":
    guard let raw = args.flags["scope"], let scope = Scope(rawValue: raw) else {
        fail("run needs --scope device or --scope session")
    }
    requireRootIfDevice(scope)
    let p = paths(for: scope)
    guard let lock = RunLock(url: p.lock) else {
        print("another \(scope.rawValue) run is in progress; exiting")
        exit(0)
    }
    let interactive = isatty(STDOUT_FILENO) == 1
    let log = AgentLog(url: p.log, echoToStdout: interactive || args.has("dry-run"))
    let subject = scope == .device ? "device" : NSUserName()

    let config: AgentConfig
    switch loadConfig(args, paths: p, updateCache: scope == .device && !args.has("dry-run")) {
    case .loaded(let c, .managed):
        config = c
    case .loaded(let c, .cache(let reason)):
        log.event(scope: scope, "using last good config (version \(c.configVersion)): \(reason)")
        config = c
    case .unavailable(let reason):
        log.event(scope: scope, "waiting for config: \(reason)")
        exit(0)
    }

    if scope == .session, config.allExcludedUsers.contains(subject) {
        exit(0)   // e.g. the IT admin account: leave it untouched
    }

    let state: StateStore
    do { state = try StateStore(url: p.stateDB) } catch { fail("\(error)", code: 1) }
    let runner = Runner(modules: ModuleRegistry.all, state: state, log: log, shell: shell,
                        system: LiveSystemInfo(shell: shell), paths: p)
    var options = RunOptions(scope: scope, subject: subject, only: args.flags["module"],
                             force: args.has("force"), dryRun: args.has("dry-run"))
    options.forceModules = FleetRequests.load(.device()).modulesToForce(state: state, subject: subject)
    let started = Date()
    var summary = runner.run(config: config, options: options)
    // The daemon kickstarts us after device changes, but launchd drops that if we're still running
    // (e.g. waiting on the browser prompt). If the device changed something meanwhile, go once more.
    if scope == .session, !options.dryRun,
       let device = try? StateStore(url: Paths.device().stateDB, readOnly: true),
       device.all().contains(where: { ($0.result == .changed || $0.result == .drift) && $0.lastRun > started }) {
        summary = runner.run(config: config, options: options)
    }
    if let only = args.flags["module"], summary.results.isEmpty,
       !ModuleRegistry.all.contains(where: { $0.id == only && $0.scope == scope }) {
        fail("no \(scope.rawValue) module called \(only)")
    }
    // Device work (new apps, printers...) can unblock session modules that were waiting, e.g. the
    // Dock waiting for Chrome. Start the logged-in user's session run now rather than at next login.
    if scope == .device, !args.has("dry-run"),
       summary.results.values.contains(where: { $0 == .changed || $0 == .drift }),
       let user = LiveSystemInfo(shell: shell).consoleUser(),
       let uid = shell.run("/usr/bin/id", ["-u", user]).trimmedOutput.nonEmpty {
        _ = shell.run("/bin/launchctl", ["kickstart", "gui/\(uid)/\(AgentIdentity.sessionLabel)"])
    }
    // Fresh status for the console straight after a device run.
    if scope == .device, !args.has("dry-run"), let console = config.console {
        sendReport(console: console, configVersion: config.configVersion)
    }
    withExtendedLifetime(lock) {}
    exit(summary.failed ? 1 : 0)

case "report":
    // Run by its own LaunchDaemon every 10 minutes: tell the console how this Mac is, pick up actions.
    guard getuid() == 0 else { fail("report must run as root (try sudo)") }
    guard case .loaded(let config, _) = ConfigLoader(paths: .device()).load(updateCache: false),
          let console = config.console else {
        exit(0)   // no console configured: nothing to do
    }
    sendReport(console: console, configVersion: config.configVersion, verbose: isatty(STDOUT_FILENO) == 1)

case "listen":
    // Kept running by its own LaunchDaemon: holds a request open to the console so its buttons
    // (Check now, Update, Re-apply) reach this Mac within seconds. Results go back in a report.
    guard getuid() == 0 else { fail("listen must run as root") }
    let listenShell = SystemCommandRunner()
    var serial: String?
    while true {
        guard case .loaded(let config, _) = ConfigLoader(paths: .device()).load(updateCache: false),
              let console = config.console else { sleep(300); continue }
        if serial == nil { serial = try? LiveSystemInfo(shell: listenShell).hardware().serial }
        guard let mySerial = serial else { sleep(60); continue }
        let reporter = FleetReporter(console: console, paths: .device(), shell: listenShell,
                                     system: LiveSystemInfo(shell: listenShell))
        do {
            let actions = try reporter.wait(serial: mySerial)
            if !actions.isEmpty {
                reporter.handle(actions, serial: mySerial)
                sendReport(console: console, configVersion: config.configVersion)   // results back now
            }
        } catch {
            sleep(30)   // console off or unreachable: try again shortly
        }
    }

case "status":
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    print("macagent \(AgentVersion.current)")
    switch ConfigLoader(paths: .device()).load(updateCache: false) {
    case .loaded(let c, .managed): print("config: version \(c.configVersion), from Intune")
    case .loaded(let c, .cache(let why)): print("config: version \(c.configVersion), from cache (\(why))")
    case .unavailable(let why): print("config: none (\(why))")
    }

    var stores: [(String, URL)] = [("device", Paths.device().stateDB)]
    let users = (try? FileManager.default.contentsOfDirectory(atPath: "/Users")) ?? []
    for user in users.sorted() where !user.hasPrefix(".") && user != "Shared" {
        let home = URL(fileURLWithPath: "/Users/\(user)")
        stores.append(("session", Paths.session(home: home).stateDB))
    }
    print("")
    print("SUBJECT".padding(toLength: 18, withPad: " ", startingAt: 0) + "MODULE".padding(toLength: 18, withPad: " ", startingAt: 0)
          + "RESULT".padding(toLength: 9, withPad: " ", startingAt: 0) + "LAST RUN".padding(toLength: 18, withPad: " ", startingAt: 0) + "DETAIL")
    var any = false
    for (_, url) in stores where FileManager.default.isReadableFile(atPath: url.path) {
        guard let store = try? StateStore(url: url) else { continue }
        for s in store.all() {
            any = true
            print(s.subject.padding(toLength: 18, withPad: " ", startingAt: 0)
                  + s.module.padding(toLength: 18, withPad: " ", startingAt: 0)
                  + s.result.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
                  + formatter.string(from: s.lastRun).padding(toLength: 18, withPad: " ", startingAt: 0)
                  + s.detail)
        }
    }
    if !any { print("(no runs recorded\(getuid() == 0 ? "" : "; run with sudo to see device state"))") }

case "config":
    switch loadConfig(args, paths: .device(), updateCache: false) {
    case .loaded(let c, let source):
        if case .cache(let why) = source { print("using cached config because: \(why)\n") }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        print(String(decoding: (try? encoder.encode(c)) ?? Data(), as: UTF8.self))
    case .unavailable(let why):
        fail(why, code: 1)
    }

case "state":
    guard args.positional.first == "reset" else { fail("usage: macagent state reset [ID] [--scope device|session]") }
    let scope = scopeArg(args, default: .device)
    requireRootIfDevice(scope)
    let module = args.positional.dropFirst().first
    do {
        try StateStore(url: paths(for: scope).stateDB).reset(module: module)
        print("reset \(module ?? "all modules") (\(scope.rawValue)); it will re-apply on the next run")
    } catch {
        fail("\(error)", code: 1)
    }

case "hash-password":
    func ask(_ prompt: String) -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        guard let p = readpassphrase(prompt, &buf, buf.count, 0) else { fail("no terminal to read the password from") }
        return String(cString: p)
    }
    let first = ask("New admin password: ")
    guard first.count >= 8 else { fail("use at least 8 characters") }
    if first.count < 12 {
        FileHandle.standardError.write(Data("note: under 12 characters is easier to guess if the hash leaks\n".utf8))
    }
    guard ask("Again: ") == first else { fail("the two passwords didn't match") }
    let hash = PasswordHash.make(password: first)
    print("\nPaste this into AdminAccount > PasswordHash in the Intune config:\n\n\(hash.string)\n")

case "desktop":
    let desktop = LiveDesktop()
    print("wallpaper:       \(desktop.wallpaper()?.path ?? "(unknown)")")
    print("default browser: \(desktop.defaultBrowser()?.path ?? "(none)")")

case "version", "--version":
    print(AgentVersion.current)

case "help", "--help", "-h":
    print(usage)

default:
    fail("unknown command \(command)\n\n\(usage)")
}
