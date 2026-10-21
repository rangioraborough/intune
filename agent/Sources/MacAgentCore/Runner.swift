import Foundation

public struct RunOptions: Sendable {
    public var scope: Scope
    public var subject: String
    /// Only run this module.
    public var only: String?
    /// Run `once` modules even if already applied.
    public var force: Bool
    /// Report what would change without changing anything or saving state.
    public var dryRun: Bool

    public init(scope: Scope, subject: String, only: String? = nil, force: Bool = false, dryRun: Bool = false) {
        self.scope = scope
        self.subject = subject
        self.only = only
        self.force = force
        self.dryRun = dryRun
    }
}

public struct RunSummary: Equatable, Sendable {
    public var results: [String: RunResult] = [:]
    public var failed: Bool { results.values.contains(.fail) }
}

public struct Runner: Sendable {
    public var modules: [Module]
    public var state: StateStore
    public var log: AgentLog
    public var shell: CommandRunner
    public var system: SystemInfo
    public var prefs: PreferencesStore
    public var paths: Paths
    public var now: @Sendable () -> Date = { Date() }
    /// Tests only: replace the state lookup behind `appliedAnywhere`.
    var appliedOverride: (@Sendable (String) -> Bool)?

    public init(modules: [Module], state: StateStore, log: AgentLog, shell: CommandRunner,
                system: SystemInfo, prefs: PreferencesStore = UserPreferences(), paths: Paths) {
        self.modules = modules
        self.state = state
        self.log = log
        self.shell = shell
        self.system = system
        self.prefs = prefs
        self.paths = paths
    }

    /// Checks this run's own state, then every user's session state under `paths.usersDir`.
    public var appliedAnywhere: @Sendable (String) -> Bool {
        if let appliedOverride { return appliedOverride }
        let state = state, usersDir = paths.usersDir
        return { module in
            if state.all().contains(where: { $0.module == module && $0.result.isApplied }) { return true }
            let users = (try? FileManager.default.contentsOfDirectory(atPath: usersDir.path)) ?? []
            for user in users where !user.hasPrefix(".") {
                let db = Paths.session(home: usersDir.appendingPathComponent(user)).stateDB
                guard FileManager.default.isReadableFile(atPath: db.path),
                      let store = try? StateStore(url: db) else { continue }
                if store.all().contains(where: { $0.module == module && $0.result.isApplied }) { return true }
            }
            return false
        }
    }

    public func run(config: AgentConfig, options: RunOptions) -> RunSummary {
        var summary = RunSummary()
        let selected = modules.filter { $0.scope == options.scope && (options.only == nil || $0.id == options.only) }

        for module in selected {
            guard let hash = module.configHash(config) else { continue }   // disabled or unconfigured
            let previous = state.get(module: module.id, subject: options.subject)

            if module.enforce == .once, !options.force,
               let previous, previous.configHash == hash, previous.result.isApplied {
                continue   // applied for this config already; the user owns it now
            }

            var data = previous?.data ?? [:]
            let context = ModuleContext(config: config, subject: options.subject, dryRun: options.dryRun,
                                        force: options.force, shell: shell, system: system, prefs: prefs,
                                        paths: paths, appliedAnywhere: appliedAnywhere)
            let started = now()
            var result: RunResult
            var detail: String
            do {
                switch try module.run(context, data: &data) {
                case .ok(let d): result = .ok; detail = d
                case .changed(let d): result = .changed; detail = d
                case .drift(let d): result = .drift; detail = d
                case .waiting(let d): result = .waiting; detail = d
                }
            } catch {
                result = .fail
                detail = (error as? ModuleError)?.message ?? "\(error)"
                // Discard anything the module recorded before failing, so a half-done run is never
                // remembered as done.
                data = previous?.data ?? [:]
            }
            let duration = now().timeIntervalSince(started)

            // A change under an unchanged config, after it was already applied, means something undid it.
            if result == .changed, module.enforce == .always,
               let previous, previous.configHash == hash, previous.result.isApplied {
                result = .drift
            }

            summary.results[module.id] = result
            if options.dryRun {
                log.module(scope: options.scope, id: module.id, result: "dry-run", duration: duration,
                           configHash: hash, detail: "\(result.rawValue): \(detail)")
                continue
            }
            log.module(scope: options.scope, id: module.id, result: result.rawValue, duration: duration,
                       configHash: hash, detail: detail)
            do {
                try state.put(ModuleState(module: module.id, subject: options.subject, configHash: hash,
                                          lastRun: started, result: result, duration: duration, detail: detail,
                                          agentVersion: AgentVersion.current, data: data))
            } catch {
                log.event(scope: options.scope, "could not save state for \(module.id): \(error)")
            }
        }
        return summary
    }
}

/// Exclusive, non-blocking lock so overlapping launchd triggers (timer + config change) don't run twice.
public final class RunLock {
    private let fd: Int32

    public init?(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
