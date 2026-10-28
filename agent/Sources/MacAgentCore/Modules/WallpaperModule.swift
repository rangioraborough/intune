import Foundation

/// Sets each user's wallpaper once from the site resources, through the user's own session
/// (NSWorkspace). No AppleScript to Finder, so no permission prompt and no -1712 timeouts.
public struct WallpaperModule: Module {
    public let id = "wallpaper"
    public let scope = Scope.session
    public let enforce = Enforce.once

    let desktop: Desktop?

    public init(desktop: Desktop? = nil) { self.desktop = desktop }

    public func configHash(_ config: AgentConfig) -> String? { config.wallpaper.map(ConfigHash.of) }

    public func run(_ ctx: ModuleContext, data: inout [String: String]) throws -> Outcome {
        guard let cfg = ctx.config.wallpaper else { return .ok("not configured") }
        let image = ctx.paths.siteResources.appendingPathComponent(cfg.image)
        guard ctx.system.fileExists(image.path) else {
            return .waiting("\(cfg.image) isn't installed yet (site resources package)")
        }
        let desktop = desktop ?? LiveDesktop()
        if desktop.wallpaper()?.standardizedFileURL == image.standardizedFileURL {
            return .ok("wallpaper already set")
        }
        if !ctx.dryRun { try desktop.setWallpaper(image) }
        return .changed("wallpaper set to \(cfg.image)")
    }
}
