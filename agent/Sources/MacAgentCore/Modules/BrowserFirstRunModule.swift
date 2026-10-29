import Foundation

/// Stops the default browser showing its own first-run welcome, by creating the marker file the
/// browser writes once that welcome is done. Runs at login, before the user first opens it.
/// Chrome's welcome asks to become the default (DefaultBrowserModule already does that) and to send
/// usage statistics to Google, which then stays off.
public struct BrowserFirstRunModule: Module {
    public let id = "browser-first-run"
    public let scope = Scope.session
    public let enforce = Enforce.once

    /// Browser app name → its first-run marker, relative to the user's home.
    static let markers = [
        "Google Chrome": "Library/Application Support/Google/Chrome/First Run",
    ]

    let home: URL?

    public init(home: URL? = nil) { self.home = home }

    public func configHash(_ config: AgentConfig) -> String? {
        guard let cfg = config.defaultBrowser, cfg.skipFirstRun == true else { return nil }
        return ConfigHash.of(cfg)
    }

    public func run(_ ctx: ModuleContext, data: inout [String: String]) throws -> Outcome {
        guard let cfg = ctx.config.defaultBrowser else { return .ok("not configured") }
        let name = DockModule.appName(cfg.app)
        guard let marker = Self.markers[name] else { return .ok("\(name) has no first-run welcome to skip") }
        let url = (home ?? FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent(marker)
        if FileManager.default.fileExists(atPath: url.path) { return .ok("\(name) first run already done") }
        if ctx.dryRun { return .changed("would skip \(name)'s first-run welcome") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw ModuleError("couldn't create \(url.path)")
        }
        return .changed("skipped \(name)'s first-run welcome")
    }
}
