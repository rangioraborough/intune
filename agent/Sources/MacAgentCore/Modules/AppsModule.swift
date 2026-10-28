import Foundation

/// Installs what's missing: Rosetta, apps via the bundled Installomator (which checks each vendor's
/// Team ID), and packages shipped in the site resources. Never updates; apps update themselves.
/// Replaces InstallApps.sh + InstallApps-worker.sh and InstallCompanyPortal.sh.
public struct AppsModule: Module {
    public let id = "apps"
    public let scope = Scope.device
    public let enforce = Enforce.always

    public init() {}

    static let installomator = AgentIdentity.appPath + "/Contents/Resources/Installomator.sh"
    static let rosettaRuntime = "/Library/Apple/usr/libexec/oah/libRosettaRuntime"

    public func configHash(_ config: AgentConfig) -> String? { config.apps.map(ConfigHash.of) }

    struct WaitingError: Error { let message: String }

    /// How long replaceable apps must be untouched before the agent swaps them.
    static let settleTime: TimeInterval = 10 * 60

    /// Site file path, or download the URL to a temp file and check its SHA-256.
    static func fetch(_ pkg: AppsConfig.PackageEntry, ctx: ModuleContext) throws -> String {
        if let file = pkg.file {
            let path = ctx.paths.siteResources.appendingPathComponent(file).path
            guard ctx.system.fileExists(path) else { throw WaitingError(message: "\(file) (site resources not installed)") }
            return path
        }
        guard let url = pkg.url, let expected = pkg.sha256?.lowercased() else { throw ModuleError("\(pkg.name): no File or URL") }
        let dest = "/private/var/tmp/macagent-\(UUID().uuidString).pkg"
        let r = ctx.shell.run("/usr/bin/curl", ["-fsSL", "--retry", "3", "--connect-timeout", "30", "-o", dest, url])
        guard r.succeeded else { throw ModuleError("\(pkg.name): download failed (curl \(r.exitCode))") }
        let sum = ctx.shell.run("/usr/bin/openssl", ["dgst", "-sha256", "-r", dest]).stdout
            .split(separator: " ").first.map(String.init)?.lowercased()
        guard sum == expected else {
            try? FileManager.default.removeItem(atPath: dest)
            throw ModuleError("\(pkg.name): download doesn't match its SHA256 (got \(sum ?? "nothing"))")
        }
        return dest
    }

    public func run(_ ctx: ModuleContext, data: inout [String: String]) throws -> Outcome {
        guard let cfg = ctx.config.apps else { return .ok("not configured") }
        var installed: [String] = []
        var failures: [String] = []
        var waiting: [String] = []

        let appleSilicon = ctx.shell.run("/usr/sbin/sysctl", ["-n", "hw.optional.arm64"]).trimmedOutput == "1"
        var hasRosetta = !appleSilicon || ctx.system.fileExists(Self.rosettaRuntime)
        if cfg.rosetta ?? false, !hasRosetta {
            if ctx.dryRun { installed.append("Rosetta") } else {
                _ = ctx.shell.run("/usr/sbin/softwareupdate", ["--install-rosetta", "--agree-to-license"])
                // softwareupdate can exit 0 without installing; check the runtime is really there.
                hasRosetta = ctx.system.fileExists(Self.rosettaRuntime)
                if hasRosetta { installed.append("Rosetta") } else { failures.append("Rosetta didn't install") }
            }
        }

        for pkg in cfg.packages ?? [] {
            if let app = pkg.app, let version = pkg.version {
                if ctx.system.appVersion(app) == version { continue }
            } else if let receipt = pkg.receipt, ctx.shell.run("/usr/sbin/pkgutil", ["--pkg-info", receipt]).succeeded {
                continue
            }
            if pkg.needsRosetta ?? false, !hasRosetta { waiting.append("\(pkg.name) (needs Rosetta)"); continue }
            let replace = (pkg.replaceApps ?? []).filter(ctx.system.fileExists)
            let open = replace.map(DockModule.appName).filter { ctx.shell.run("/usr/bin/pgrep", ["-x", $0]).succeeded }
            if !open.isEmpty {
                waiting.append("\(pkg.name) (\(open.joined(separator: ", ")) open; will swap when closed)")
                continue
            }
            // Something (e.g. Intune) may be installing these apps right now; never pull them out
            // from under an installer. Wait until they've been left alone for a while.
            let busy = replace.filter { ctx.system.modified($0).map { Date().timeIntervalSince($0) < Self.settleTime } ?? false }
            if !busy.isEmpty {
                waiting.append("\(pkg.name) (\(busy.map(DockModule.appName).joined(separator: ", ")) changed in the last few minutes; will check again later)")
                continue
            }
            if ctx.dryRun { installed.append(pkg.name); continue }
            do {
                let path = try Self.fetch(pkg, ctx: ctx)
                defer { if pkg.url != nil { try? FileManager.default.removeItem(atPath: path) } }
                if let team = pkg.teamID {
                    let sig = ctx.shell.run("/usr/sbin/pkgutil", ["--check-signature", path]).stdout
                    guard sig.contains("(\(team))") else { throw ModuleError("\(pkg.name) isn't signed by Team ID \(team)") }
                }
                // Installers won't downgrade, so remove the apps first. Only now, after the download
                // and signature check succeeded. If a removal fails, carry on: the installer must run
                // either way, so the Mac is never left without the apps.
                var notRemoved: [String] = []
                for app in replace {
                    do { try FileManager.default.removeItem(at: ctx.paths.resolve(app)) }
                    catch { notRemoved.append(DockModule.appName(app)) }
                }
                let r = ctx.shell.run("/usr/sbin/installer", ["-pkg", path, "-target", "/"])
                guard r.succeeded else { throw ModuleError("\(pkg.name): installer exited \(r.exitCode)") }
                if !notRemoved.isEmpty, let app = pkg.app, let version = pkg.version, ctx.system.appVersion(app) != version {
                    throw ModuleError("\(pkg.name): couldn't remove \(notRemoved.joined(separator: ", ")) to replace it; apps reinstalled, will retry")
                }
                if let app = pkg.app, let version = pkg.version, ctx.system.appVersion(app) != version {
                    throw ModuleError("\(pkg.name) installed but \(DockModule.appName(app)) is \(ctx.system.appVersion(app) ?? "missing"), not \(version)")
                }
                installed.append(pkg.name)
            } catch let e as WaitingError {
                waiting.append(e.message)
            } catch {
                failures.append((error as? ModuleError)?.message ?? "\(pkg.name): \(error)")
            }
        }

        for app in cfg.install ?? [] where !ctx.system.fileExists(app.path) {
            let name = DockModule.appName(app.path)
            if ctx.dryRun { installed.append(name); continue }
            let r = ctx.shell.run("/bin/zsh", [Self.installomator, app.label, "DEBUG=0", "NOTIFY=silent",
                                               "BLOCKING_PROCESS_ACTION=ignore", "LOGGING=WARN"])
            if r.succeeded, ctx.system.fileExists(app.path) {
                installed.append(name)
            } else {
                let why = r.stdout.split(separator: "\n").last(where: { $0.contains("ERROR") }).map(String.init)
                failures.append("\(name): Installomator \(app.label) exited \(r.exitCode)" + (why.map { " (\($0))" } ?? ""))
            }
        }

        // Unwanted apps, e.g. OneDrive and Teams that Microsoft's installers (or Intune) bring along.
        var removed: [String] = []
        for app in cfg.remove ?? [] where ctx.system.fileExists(app) {
            removed.append(DockModule.appName(app))
            if ctx.dryRun { continue }
            _ = ctx.shell.run("/usr/bin/pkill", ["-f", app + "/Contents/MacOS/"])   // quit it if running
            do { try FileManager.default.removeItem(at: ctx.paths.resolve(app)) }
            catch { failures.append("couldn't remove \(DockModule.appName(app)): \(error.localizedDescription)") }
        }
        if !removed.isEmpty { installed.append("removed " + removed.joined(separator: ", ")) }

        let summary = installed.isEmpty ? "" : "installed " + installed.joined(separator: ", ")
        if !failures.isEmpty {
            throw ModuleError(([summary].filter { !$0.isEmpty } + failures).joined(separator: "; "))
        }
        if !installed.isEmpty { return .changed(summary + (waiting.isEmpty ? "" : "; waiting for " + waiting.joined(separator: ", "))) }
        if !waiting.isEmpty { return .waiting("waiting for " + waiting.joined(separator: ", ")) }
        return .ok("all apps installed")
    }
}
