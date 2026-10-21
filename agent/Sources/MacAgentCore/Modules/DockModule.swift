import Foundation

/// Builds each user's Dock once from `Dock.Apps`, using whatever is installed at the time. Apps that
/// install later are slotted into their place in the list once, without disturbing anything the
/// user has changed. A config change rebuilds once more; `--force` rebuilds now.
public struct DockModule: Module {
    public let id = "dock"
    public let scope = Scope.session
    public let enforce = Enforce.module

    static let domain = "com.apple.dock"

    public init() {}

    public func configHash(_ config: AgentConfig) -> String? {
        guard let dock = config.dock, dock.enabled ?? true else { return nil }
        return ConfigHash.of(dock)
    }

    public func run(_ ctx: ModuleContext, data: inout [String: String]) throws -> Outcome {
        guard let dock = ctx.config.dock, let hash = configHash(ctx.config) else { return .ok("not configured") }
        let installed = dock.apps.filter(ctx.system.fileExists)
        let missing = dock.apps.filter { !installed.contains($0) }
        let missingNote = missing.isEmpty ? "" : "; waiting for " + missing.map(Self.appName).joined(separator: ", ")

        var tiles = ctx.prefs.value("persistent-apps", domain: Self.domain) as? [Any] ?? []
        let detail: String

        if ctx.force || data["builtHash"] != hash {
            tiles = installed.map(Self.tile)
            if !ctx.dryRun, let showRecents = dock.showRecents {
                ctx.prefs.set("show-recents", NSNumber(value: showRecents), domain: Self.domain)
            }
            data["builtHash"] = hash
            data["placed"] = installed.joined(separator: "\n")
            detail = "built Dock with \(installed.count) of \(dock.apps.count) apps" + missingNote
        } else {
            var placed = Set((data["placed"] ?? "").split(separator: "\n").map(String.init))
            let newlyInstalled = installed.filter { !placed.contains($0) }
            guard !newlyInstalled.isEmpty else {
                return .ok("Dock already built" + missingNote)
            }
            var added: [String] = []
            for app in newlyInstalled {
                placed.insert(app)
                if tiles.contains(where: { Self.path(of: $0) == app }) { continue }  // user already added it
                tiles.insert(Self.tile(for: app), at: Self.slot(for: app, in: tiles, order: dock.apps))
                added.append(Self.appName(app))
            }
            data["placed"] = dock.apps.filter(placed.contains).joined(separator: "\n")
            guard !added.isEmpty else { return .ok("Dock already built" + missingNote) }
            detail = "added " + added.joined(separator: ", ") + missingNote
        }

        if !ctx.dryRun {
            ctx.prefs.set("persistent-apps", tiles as NSArray, domain: Self.domain)
            guard ctx.prefs.synchronize(domain: Self.domain) else {
                throw ModuleError("could not save \(Self.domain)")
            }
            _ = ctx.shell.run("/usr/bin/killall", ["Dock"])   // exits 1 if Dock isn't running; fine
        }
        return .changed(detail)
    }

    /// Insert after the nearest earlier app from the list that's in the Dock; failing that, before
    /// the nearest later one; failing that, at the end.
    static func slot(for app: String, in tiles: [Any], order: [String]) -> Int {
        let paths = tiles.map(path(of:))
        guard let index = order.firstIndex(of: app) else { return tiles.count }
        for earlier in order[..<index].reversed() {
            if let i = paths.lastIndex(of: earlier) { return i + 1 }
        }
        for later in order[(index + 1)...] {
            if let i = paths.firstIndex(of: later) { return i }
        }
        return tiles.count
    }

    static func tile(for app: String) -> Any {
        [
            "tile-data": [
                "file-data": [
                    "_CFURLString": URL(fileURLWithPath: app, isDirectory: true).absoluteString,
                    "_CFURLStringType": 15,
                ],
            ],
            "tile-type": "file-tile",
        ] as NSDictionary
    }

    static func path(of tile: Any) -> String? {
        guard let tile = tile as? [String: Any],
              let tileData = tile["tile-data"] as? [String: Any],
              let fileData = tileData["file-data"] as? [String: Any],
              let urlString = fileData["_CFURLString"] as? String,
              let url = URL(string: urlString) else { return nil }
        return url.path
    }

    static func appName(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
