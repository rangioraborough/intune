import Foundation

/// Asks each user once to make the configured browser their default. macOS only allows this with
/// the user's consent, so the system shows its own confirmation; whatever they choose is kept.
public struct DefaultBrowserModule: Module {
    public let id = "default-browser"
    public let scope = Scope.session
    public let enforce = Enforce.once

    let desktop: Desktop?
    static let retryAfter: TimeInterval = 12 * 3600

    public init(desktop: Desktop? = nil) { self.desktop = desktop }

    public func configHash(_ config: AgentConfig) -> String? { config.defaultBrowser.map(ConfigHash.of) }

    public func run(_ ctx: ModuleContext, data: inout [String: String]) throws -> Outcome {
        guard let cfg = ctx.config.defaultBrowser else { return .ok("not configured") }
        let name = DockModule.appName(cfg.app)
        guard ctx.system.fileExists(cfg.app) else { return .waiting("\(name) isn't installed yet") }
        let desktop = desktop ?? LiveDesktop()
        let app = URL(fileURLWithPath: cfg.app)
        if desktop.defaultBrowser()?.standardizedFileURL == app.standardizedFileURL {
            return .ok("\(name) is the default browser")
        }
        if ctx.dryRun { return .changed("would ask to make \(name) the default browser") }
        // Nobody answered last time: don't put the prompt up (and hold the session run) on every
        // run. Try again after a while, e.g. at the next day's login.
        if let last = data["lastAsked"].flatMap(Double.init), Date().timeIntervalSince1970 - last < Self.retryAfter, !ctx.force {
            return .waiting("asked to make \(name) the default browser; no answer yet, will ask again later")
        }
        switch desktop.requestDefaultBrowser(app) {
        case .agreed:
            return .changed("\(name) is now the default browser")
        case .declined:
            return .ok("asked once; the user kept \(desktop.defaultBrowser().map { DockModule.appName($0.path) } ?? "their browser")")
        case .noAnswer:
            data["lastAsked"] = String(Date().timeIntervalSince1970)
            return .waiting("asked to make \(name) the default browser; no answer yet, will ask again later")
        }
    }
}
