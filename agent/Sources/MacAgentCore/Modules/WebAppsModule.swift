import Foundation

/// Builds small apps in /Applications that open a web address in a chosen browser, such as
/// Classview. Rebuilt when their config changes (or if something else replaced them).
public struct WebAppsModule: Module {
    public let id = "web-apps"
    public let scope = Scope.device
    public let enforce = Enforce.always

    public init() {}

    static let marker = "MacAgentWebAppHash"

    public func configHash(_ config: AgentConfig) -> String? {
        guard let apps = config.webApps, !apps.isEmpty else { return nil }
        return ConfigHash.of(apps)
    }

    public func run(_ ctx: ModuleContext, data: inout [String: String]) throws -> Outcome {
        var built: [String] = []
        var waiting: [String] = []
        for web in ctx.config.webApps ?? [] {
            let hash = ConfigHash.of(web)
            let app = ctx.paths.resolve("/Applications/\(web.name).app")
            let info = app.appendingPathComponent("Contents/Info.plist")
            let current = (NSDictionary(contentsOf: info)?[Self.marker] as? String)
            if current == hash { continue }
            var icon: URL?
            if let file = web.icon {
                let url = ctx.paths.siteResources.appendingPathComponent(file)
                guard ctx.system.fileExists(url.path) else { waiting.append("\(web.name) icon"); continue }
                icon = url
            }
            built.append(web.name)
            if !ctx.dryRun { try build(web, at: app, icon: icon, hash: hash, shell: ctx.shell) }
        }
        if !built.isEmpty { return .changed("built " + built.joined(separator: ", ")) }
        if !waiting.isEmpty { return .waiting(waiting.joined(separator: ", ") + " not installed yet (site resources package)") }
        return .ok("web apps up to date")
    }

    func build(_ web: WebAppConfig, at app: URL, icon: URL?, hash: String, shell: CommandRunner) throws {
        let fm = FileManager.default
        let replacing = fm.fileExists(atPath: app.path)
        if replacing { try fm.removeItem(at: app) }
        let macos = app.appendingPathComponent("Contents/MacOS")
        let resources = app.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        let open = web.browser.map { "/usr/bin/open -a \(Self.shellQuote($0)) \(Self.shellQuote(web.url))" }
            ?? "/usr/bin/open \(Self.shellQuote(web.url))"
        let launcher = macos.appendingPathComponent("launch")
        try Data("#!/bin/sh\nexec \(open)\n".utf8).write(to: launcher)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        var plist: [String: Any] = [
            "CFBundleExecutable": "launch",
            "CFBundleIdentifier": "\(AgentIdentity.bundleID).webapp.\(Self.slug(web.name))",
            "CFBundleName": web.name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            Self.marker: hash,
        ]
        if let icon {
            try fm.copyItem(at: icon, to: resources.appendingPathComponent("AppIcon.icns"))
            plist["CFBundleIconFile"] = "AppIcon"
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))

        // Launch Services and the Dock cache icons; re-register so a replaced icon shows straight away.
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        _ = shell.run(lsregister, ["-f", app.path])
        if replacing { _ = shell.run("/usr/bin/killall", ["Dock"]) }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func slug(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }
}
