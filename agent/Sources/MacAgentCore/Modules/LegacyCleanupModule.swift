import Foundation

/// Removes what the old Intune shell scripts left on a Mac, one script at a time, and only once the
/// agent module that replaces it has applied successfully here. Their logs are archived to
/// /Library/Logs/MacAgent/legacy and pruned after `KeepArchiveDays`.
///
/// If a script's folder reappears after it was cleaned, the old script is still assigned in Intune
/// and is running alongside the agent; that is reported as drift so it shows up in the log.
public struct LegacyCleanupModule: Module {
    public let id = "legacy-cleanup"
    public let scope = Scope.device
    public let enforce = Enforce.module

    public init() {}

    struct LegacyScript {
        let name: String
        let replacedBy: String
        var extraPaths: [String] = []
        var launchdLabels: [String] = []
    }

    /// The old scripts/macOS/*.sh, what replaces each, and anything they left outside their log folder.
    /// Entries whose module doesn't exist yet simply never trigger.
    static let scripts: [LegacyScript] = [
        LegacyScript(name: "DeviceRename", replacedBy: "device-name"),
        LegacyScript(name: "ConfigureDock", replacedBy: "dock"),
        LegacyScript(name: "ConfigureFinder", replacedBy: "preferences"),
        LegacyScript(name: "SetDefaultBrowser", replacedBy: "default-browser"),
        LegacyScript(name: "SetWallpaper", replacedBy: "wallpaper", extraPaths: ["/Library/RBS/Wallpaper"]),
        LegacyScript(name: "SetUserAvatar", replacedBy: "avatar", extraPaths: ["/Library/RBS/Avatars"]),
        LegacyScript(name: "InstallApps", replacedBy: "apps",
                     extraPaths: ["/Library/LaunchDaemons/nz.school.rangiora.installapps-worker.plist"],
                     launchdLabels: ["nz.school.rangiora.installapps-worker"]),
        LegacyScript(name: "InstallCompanyPortal", replacedBy: "apps"),
        LegacyScript(name: "DisableMAU", replacedBy: "mau-disable"),
        LegacyScript(name: "CreateAdminAccount", replacedBy: "admin-account"),
        LegacyScript(name: "ConfigurePrinters", replacedBy: "printer-queues",
                     extraPaths: ["/Applications/Update Printer Details.app"]),   // now in the MacAgent window
    ]

    static let scriptLogs = "/Library/Logs/Microsoft/IntuneScripts"
    /// Removed once whatever the old scripts put in it is gone.
    static let rbsDir = "/Library/RBS"

    public func configHash(_ config: AgentConfig) -> String? {
        let c = config.legacyCleanup ?? LegacyCleanupConfig()
        guard c.enabled ?? true else { return nil }
        return ConfigHash.of(c)
    }

    public func run(_ ctx: ModuleContext, data: inout [String: String]) throws -> Outcome {
        let fm = FileManager.default
        let keepDays = ctx.config.legacyCleanup?.keepArchiveDays ?? 30
        let stamp = Self.stampFormatter.string(from: Date())
        var cleaned: [String] = []
        var reran: [String] = []

        for script in Self.scripts where ctx.appliedAnywhere(script.replacedBy) {
            let folder = ctx.paths.resolve("\(Self.scriptLogs)/\(script.name)")
            let extras = script.extraPaths.map(ctx.paths.resolve).filter { fm.fileExists(atPath: $0.path) }
            let hasFolder = fm.fileExists(atPath: folder.path)
            guard hasFolder || !extras.isEmpty else { continue }

            if hasFolder, data["cleaned.\(script.name)"] != nil { reran.append(script.name) }
            cleaned.append(script.name)
            guard !ctx.dryRun else { continue }

            for label in script.launchdLabels {
                _ = ctx.shell.run("/bin/launchctl", ["bootout", "system/\(label)"])   // fine if not loaded
            }
            if hasFolder {
                try fm.createDirectory(at: ctx.paths.legacyArchive, withIntermediateDirectories: true)
                var dest = ctx.paths.legacyArchive.appendingPathComponent("\(script.name)-\(stamp)")
                var n = 2
                while fm.fileExists(atPath: dest.path) {   // cleaned twice within the same second
                    dest = ctx.paths.legacyArchive.appendingPathComponent("\(script.name)-\(stamp)-\(n)")
                    n += 1
                }
                do { try fm.moveItem(at: folder, to: dest) }
                catch { throw ModuleError("could not archive \(folder.path): \(error.localizedDescription)") }
            }
            for path in extras {
                do { try fm.removeItem(at: path) }
                catch { throw ModuleError("could not remove \(path.path): \(error.localizedDescription)") }
            }
            data["cleaned.\(script.name)"] = stamp
        }

        if !ctx.dryRun {
            removeIfEmpty(ctx.paths.resolve(Self.rbsDir))
            removeIfEmpty(ctx.paths.resolve(Self.scriptLogs))
            pruneArchive(ctx.paths.legacyArchive, keepDays: keepDays)
        }

        if !reran.isEmpty {
            return .drift(reran.joined(separator: ", ")
                          + " ran again from Intune after cleanup; unassign \(reran.count == 1 ? "it" : "them")"
                          + " (archived again)")
        }
        if !cleaned.isEmpty { return .changed("cleaned up " + cleaned.joined(separator: ", ")) }
        return .ok("nothing to clean up")
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private func removeIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        if contents.allSatisfy({ $0 == ".DS_Store" }) { try? fm.removeItem(at: dir) }
    }

    /// Archive folders are named <Script>-yyyyMMdd-HHmmss[-n]; drop those older than `keepDays`.
    private func pruneArchive(_ dir: URL, keepDays: Int) {
        let fm = FileManager.default
        let cutoff = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date()) ?? .distantPast
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let parts = name.split(separator: "-")
            guard parts.count >= 3, let i = parts.firstIndex(where: { $0.count == 8 && $0.allSatisfy(\.isNumber) }),
                  i + 1 < parts.count,
                  let date = Self.stampFormatter.date(from: "\(parts[i])-\(parts[i + 1])"),
                  date < cutoff else { continue }
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
