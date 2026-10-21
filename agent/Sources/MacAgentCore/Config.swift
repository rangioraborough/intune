import Foundation

/// The agent's config, as delivered by the Intune Preference file for domain nz.co.myers.macagent.
/// Keys are PascalCase in the plist to match how Intune admins usually write them.
public struct AgentConfig: Codable, Equatable, Sendable {
    public var configVersion: Int
    /// Accounts the agent never treats as "the user" (for naming, per-user work, etc).
    public var excludedUsers: [String]?
    public var deviceName: DeviceNameConfig?
    public var dock: DockConfig?
    public var preferences: [PreferenceEntry]?
    public var legacyCleanup: LegacyCleanupConfig?
    public var menuBar: MenuBarConfig?

    enum CodingKeys: String, CodingKey {
        case configVersion = "ConfigVersion"
        case excludedUsers = "ExcludedUsers"
        case deviceName = "DeviceName"
        case dock = "Dock"
        case preferences = "Preferences"
        case legacyCleanup = "LegacyCleanup"
        case menuBar = "MenuBar"
    }

    public init(configVersion: Int, excludedUsers: [String]? = nil, deviceName: DeviceNameConfig? = nil,
                dock: DockConfig? = nil, preferences: [PreferenceEntry]? = nil) {
        self.configVersion = configVersion
        self.excludedUsers = excludedUsers
        self.deviceName = deviceName
        self.dock = dock
        self.preferences = preferences
    }

    /// System accounts that are never a real user, plus anything the config adds.
    public var allExcludedUsers: Set<String> {
        Set(["root", "loginwindow", "_mbsetupuser"]).union(excludedUsers ?? [])
    }

    /// Checks that can't be expressed in the type. Returns human-readable problems.
    public func validate() -> [String] {
        var problems: [String] = []
        if configVersion < 1 { problems.append("ConfigVersion must be 1 or higher") }
        if let dn = deviceName { problems += dn.validate().map { "DeviceName: \($0)" } }
        if let dock { problems += dock.validate().map { "Dock: \($0)" } }
        if let menuBar { problems += menuBar.validate().map { "MenuBar: \($0)" } }
        if let preferences {
            for (i, entry) in preferences.enumerated() {
                problems += entry.validate().map { "Preferences[\(i)]: \($0)" }
            }
            let domains = preferences.map(\.domain)
            for d in Set(domains) where domains.filter({ $0 == d }).count > 1 {
                problems.append("Preferences: domain \(d) is listed more than once; put its settings in one entry")
            }
        }
        return problems
    }
}

public struct DeviceNameConfig: Codable, Equatable, Sendable {
    public var enabled: Bool?
    /// Placeholders: {model} {user} {username} {serial}. Default "{model}-{user}".
    public var template: String?
    /// Model-name prefix → code, merged over the built-in table. Longest matching prefix wins.
    public var modelCodes: [String: String]?

    enum CodingKeys: String, CodingKey {
        case enabled = "Enabled"
        case template = "Template"
        case modelCodes = "ModelCodes"
    }

    public init(enabled: Bool? = nil, template: String? = nil, modelCodes: [String: String]? = nil) {
        self.enabled = enabled
        self.template = template
        self.modelCodes = modelCodes
    }

    public static let placeholders = ["{model}", "{user}", "{username}", "{serial}"]

    public var resolvedTemplate: String { template ?? "{model}-{user}" }

    func validate() -> [String] {
        var problems: [String] = []
        let t = resolvedTemplate
        var stripped = t
        for p in Self.placeholders { stripped = stripped.replacingOccurrences(of: p, with: "") }
        if stripped.contains("{") || stripped.contains("}") {
            problems.append("Template \"\(t)\" has an unknown placeholder; allowed: \(Self.placeholders.joined(separator: " "))")
        }
        if !Self.placeholders.contains(where: t.contains) {
            problems.append("Template \"\(t)\" has no placeholders, so every Mac would get the same name")
        }
        return problems
    }
}

/// The menu bar app: help contact and custom links.
public struct MenuBarConfig: Codable, Equatable, Sendable {
    /// e.g. "Contact IT". Shown with HelpURL; omit both to hide the item.
    public var helpTitle: String?
    /// mailto:, https: or tel: URL.
    public var helpURL: String?
    public var items: [MenuItem]?

    enum CodingKeys: String, CodingKey {
        case helpTitle = "HelpTitle"
        case helpURL = "HelpURL"
        case items = "Items"
    }

    public init(helpTitle: String? = nil, helpURL: String? = nil, items: [MenuItem]? = nil) {
        self.helpTitle = helpTitle
        self.helpURL = helpURL
        self.items = items
    }

    public struct MenuItem: Codable, Equatable, Sendable {
        public var title: String
        public var url: String
        /// Open with this app instead of the default, e.g. "Google Chrome".
        public var app: String?
        /// SF Symbol name for the icon, e.g. "globe". Optional.
        public var symbol: String?

        enum CodingKeys: String, CodingKey {
            case title = "Title"
            case url = "URL"
            case app = "App"
            case symbol = "Symbol"
        }

        public init(title: String, url: String, app: String? = nil, symbol: String? = nil) {
            self.title = title
            self.url = url
            self.app = app
            self.symbol = symbol
        }
    }

    func validate() -> [String] {
        var problems: [String] = []
        func checkURL(_ s: String, _ what: String) {
            guard let u = URL(string: s), let scheme = u.scheme, !scheme.isEmpty else {
                problems.append("\(what) \"\(s)\" is not a full URL (needs https:, mailto: or similar)")
                return
            }
        }
        if (helpTitle == nil) != (helpURL == nil) { problems.append("set both HelpTitle and HelpURL, or neither") }
        if let helpURL { checkURL(helpURL, "HelpURL") }
        for (i, item) in (items ?? []).enumerated() {
            if item.title.isEmpty { problems.append("Items[\(i)] has an empty Title") }
            checkURL(item.url, "Items[\(i)].URL")
        }
        return problems
    }
}

public struct LegacyCleanupConfig: Codable, Equatable, Sendable {
    /// On by default; set false to leave the old Intune scripts' files alone.
    public var enabled: Bool?
    /// Days to keep archived old-script logs. Default 30.
    public var keepArchiveDays: Int?

    enum CodingKeys: String, CodingKey {
        case enabled = "Enabled"
        case keepArchiveDays = "KeepArchiveDays"
    }

    public init(enabled: Bool? = nil, keepArchiveDays: Int? = nil) {
        self.enabled = enabled
        self.keepArchiveDays = keepArchiveDays
    }
}

public struct DockConfig: Codable, Equatable, Sendable {
    public var enabled: Bool?
    /// Apps in Dock order. Missing ones are skipped and added in their slot once installed.
    public var apps: [String]
    /// Show recently used apps in the Dock. Omit to leave the user's setting alone.
    public var showRecents: Bool?

    enum CodingKeys: String, CodingKey {
        case enabled = "Enabled"
        case apps = "Apps"
        case showRecents = "ShowRecents"
    }

    public init(enabled: Bool? = nil, apps: [String], showRecents: Bool? = nil) {
        self.enabled = enabled
        self.apps = apps
        self.showRecents = showRecents
    }

    func validate() -> [String] {
        var problems: [String] = []
        if apps.isEmpty { problems.append("Apps is empty") }
        for app in apps where !app.hasPrefix("/") || !app.hasSuffix(".app") {
            problems.append("\"\(app)\" should be a full path to a .app, e.g. /Applications/Safari.app")
        }
        return problems
    }
}

/// One preference domain to set for every user, e.g. com.apple.finder.
public struct PreferenceEntry: Codable, Equatable, Sendable {
    public var domain: String
    /// Keys to set. Dictionary values are merged into the existing dictionary (like `defaults -dict-add`).
    public var settings: [String: PlistValue]
    /// `once` (default): set at first login, then the user can change them. `always`: put back every run.
    public var enforce: String?
    /// Process to restart after a change so it picks up the new values, e.g. "Finder".
    public var restart: String?

    enum CodingKeys: String, CodingKey {
        case domain = "Domain"
        case settings = "Settings"
        case enforce = "Enforce"
        case restart = "Restart"
    }

    public init(domain: String, settings: [String: PlistValue], enforce: String? = nil, restart: String? = nil) {
        self.domain = domain
        self.settings = settings
        self.enforce = enforce
        self.restart = restart
    }

    public var enforceMode: Enforce { enforce == "always" ? .always : .once }

    func validate() -> [String] {
        var problems: [String] = []
        if domain.isEmpty || domain.contains("/") { problems.append("Domain \"\(domain)\" should be a preference domain like com.apple.finder") }
        if settings.isEmpty { problems.append("\(domain): Settings is empty") }
        if let e = enforce, e != "once", e != "always" { problems.append("\(domain): Enforce must be once or always, not \(e)") }
        return problems
    }
}

public enum ConfigSource: Equatable, Sendable {
    case managed
    /// Managed config missing or invalid; using the last good one. The string says why.
    case cache(reason: String)
}

public enum ConfigLoadResult: Sendable {
    case loaded(AgentConfig, ConfigSource)
    /// Nothing usable anywhere. The agent waits rather than guessing.
    case unavailable(reason: String)
}

public struct ConfigLoader: Sendable {
    public var paths: Paths

    public init(paths: Paths) { self.paths = paths }

    /// Load the managed config, falling back to the cache. When `updateCache` is set (root daemon only)
    /// a valid managed config is written to the cache so later runs survive the profile disappearing.
    public func load(updateCache: Bool) -> ConfigLoadResult {
        let managedProblem: String
        switch Self.decode(contentsOf: paths.managedConfig) {
        case .success(let config):
            if updateCache { try? writeCache(config) }
            return .loaded(config, .managed)
        case .failure(let error):
            managedProblem = error.message
        }
        switch Self.decode(contentsOf: paths.configCache) {
        case .success(let config):
            return .loaded(config, .cache(reason: managedProblem))
        case .failure:
            return .unavailable(reason: managedProblem)
        }
    }

    public static func decode(contentsOf url: URL) -> Result<AgentConfig, ConfigError> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(ConfigError("no config at \(url.path)"))
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(ConfigError("config at \(url.path) exists but can't be read by this user"))
        }
        return decode(data: data, source: url.path)
    }

    public static func decode(data: Data, source: String) -> Result<AgentConfig, ConfigError> {
        let config: AgentConfig
        do {
            config = try PropertyListDecoder().decode(AgentConfig.self, from: data)
        } catch let error as DecodingError {
            return .failure(ConfigError("\(source): \(describe(error))"))
        } catch {
            return .failure(ConfigError("\(source): not a readable plist (\(error.localizedDescription))"))
        }
        let problems = config.validate()
        if !problems.isEmpty {
            return .failure(ConfigError("\(source): " + problems.joined(separator: "; ")))
        }
        return .success(config)
    }

    private func writeCache(_ config: AgentConfig) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(config)
        try FileManager.default.createDirectory(at: paths.configCache.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: paths.configCache, options: .atomic)
    }

    /// Turn a DecodingError into "DeviceName.Template: expected string" style text an Intune admin can act on.
    static func describe(_ error: DecodingError) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            let p = codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return p.isEmpty ? "(top level)" : p
        }
        switch error {
        case .keyNotFound(let key, let ctx):
            return "missing required key \(path(ctx.codingPath + [key]))"
        case .typeMismatch(let type, let ctx):
            return "\(path(ctx.codingPath)) has the wrong type, expected \(type)"
        case .valueNotFound(let type, let ctx):
            return "\(path(ctx.codingPath)) is empty, expected \(type)"
        case .dataCorrupted(let ctx):
            return "\(path(ctx.codingPath)): \(ctx.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }
}

public struct ConfigError: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}
