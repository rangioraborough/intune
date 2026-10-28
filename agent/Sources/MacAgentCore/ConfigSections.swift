import Foundation

/// Config sections for the device and site modules. File names (images, packages, presets) are
/// relative to the site resources folder, /Library/Application Support/MacAgent/Site, which the
/// per-school "MacAgent Site" package installs.

public struct AdminAccountConfig: Codable, Equatable, Sendable {
    public var username: String
    public var fullName: String?
    /// Hidden from the login window. Default true.
    public var hidden: Bool?
    /// From `macagent hash-password`: pbkdf2-sha512$<iterations>$<salt b64>$<entropy b64>.
    public var passwordHash: String
    /// Old admin accounts to delete, e.g. the blank-password itadmin the old script created.
    public var removeAccounts: [String]?

    enum CodingKeys: String, CodingKey {
        case username = "Username"
        case fullName = "FullName"
        case hidden = "Hidden"
        case passwordHash = "PasswordHash"
        case removeAccounts = "RemoveAccounts"
    }

    public init(username: String, fullName: String? = nil, hidden: Bool? = nil, passwordHash: String,
                removeAccounts: [String]? = nil) {
        self.username = username
        self.fullName = fullName
        self.hidden = hidden
        self.passwordHash = passwordHash
        self.removeAccounts = removeAccounts
    }

    func validate() -> [String] {
        var problems: [String] = []
        if username.isEmpty || username.contains(where: { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }) {
            problems.append("Username \"\(username)\" should be a short account name like itadmin")
        }
        if (removeAccounts ?? []).contains(username) {
            problems.append("RemoveAccounts can't include \(username), the account being managed")
        }
        if PasswordHash(string: passwordHash) == nil {
            problems.append(passwordHash.hasPrefix("pbkdf2-sha512$") || passwordHash.hasPrefix("REPLACE")
                ? "PasswordHash isn't valid; generate it with `macagent hash-password`"
                : "PasswordHash looks like a plain-text password. Never put the password itself here "
                  + "(every user can read this config); run `macagent hash-password` and paste its output")
        }
        return problems
    }
}

public struct WallpaperConfig: Codable, Equatable, Sendable {
    public var image: String

    enum CodingKeys: String, CodingKey { case image = "Image" }

    public init(image: String) { self.image = image }
}

public struct AvatarConfig: Codable, Equatable, Sendable {
    /// Picture for every user without an override.
    public var defaultImage: String?
    /// Username → picture, e.g. itadmin → avatars/admin.png. Applies even to excluded users.
    public var users: [String: String]?

    enum CodingKeys: String, CodingKey {
        case defaultImage = "Default"
        case users = "Users"
    }

    public init(defaultImage: String? = nil, users: [String: String]? = nil) {
        self.defaultImage = defaultImage
        self.users = users
    }
}

public struct DefaultBrowserConfig: Codable, Equatable, Sendable {
    /// e.g. /Applications/Google Chrome.app
    public var app: String

    enum CodingKeys: String, CodingKey { case app = "App" }

    public init(app: String) { self.app = app }
}

public struct MAUConfig: Codable, Equatable, Sendable {
    /// Turn Microsoft AutoUpdate off and keep it off.
    public var disable: Bool

    enum CodingKeys: String, CodingKey { case disable = "Disable" }

    public init(disable: Bool) { self.disable = disable }
}

public struct AppsConfig: Codable, Equatable, Sendable {
    /// Install Rosetta on Apple silicon (needed by Intel-only drivers like the Apeos plug-in).
    public var rosetta: Bool?
    /// Installomator labels, installed if their app is missing. Never updated by the agent.
    public var install: [AppEntry]?
    /// Packages shipped in the site resources, installed if their receipt is missing.
    public var packages: [PackageEntry]?
    /// Apps that must not be on the Mac (e.g. ones a vendor installer brings along). Removed every run.
    public var remove: [String]?

    enum CodingKeys: String, CodingKey {
        case rosetta = "Rosetta"
        case install = "Install"
        case packages = "Packages"
        case remove = "Remove"
    }

    public init(rosetta: Bool? = nil, install: [AppEntry]? = nil, packages: [PackageEntry]? = nil, remove: [String]? = nil) {
        self.rosetta = rosetta
        self.install = install
        self.packages = packages
        self.remove = remove
    }

    public struct AppEntry: Codable, Equatable, Sendable {
        public var label: String
        /// Where the app lands, used to tell whether it's installed.
        public var path: String

        enum CodingKeys: String, CodingKey {
            case label = "Label"
            case path = "Path"
        }

        public init(label: String, path: String) {
            self.label = label
            self.path = path
        }
    }

    /// A package from the site resources (File) or downloaded from its vendor (URL + SHA256).
    /// "Installed" means its Receipt exists, or (to hold a specific version) that App is exactly Version.
    public struct PackageEntry: Codable, Equatable, Sendable {
        public var file: String?
        public var url: String?
        /// Required with URL: the download must match exactly.
        public var sha256: String?
        /// Apple Team ID the package must be signed with, e.g. UBF8T346G9 for Microsoft.
        public var teamID: String?
        public var receipt: String?
        public var app: String?
        /// CFBundleShortVersionString the App must have; anything else (newer or older) is replaced.
        public var version: String?
        /// Apps removed before installing when App isn't Version (installers won't downgrade).
        /// Never done while any of them is open.
        public var replaceApps: [String]?
        public var needsRosetta: Bool?

        enum CodingKeys: String, CodingKey {
            case file = "File"
            case url = "URL"
            case sha256 = "SHA256"
            case teamID = "TeamID"
            case receipt = "Receipt"
            case app = "App"
            case version = "Version"
            case replaceApps = "ReplaceApps"
            case needsRosetta = "NeedsRosetta"
        }

        public init(file: String? = nil, url: String? = nil, sha256: String? = nil, teamID: String? = nil,
                    receipt: String? = nil, app: String? = nil, version: String? = nil,
                    replaceApps: [String]? = nil, needsRosetta: Bool? = nil) {
            self.file = file
            self.url = url
            self.sha256 = sha256
            self.teamID = teamID
            self.receipt = receipt
            self.app = app
            self.version = version
            self.replaceApps = replaceApps
            self.needsRosetta = needsRosetta
        }

        public var name: String {
            file ?? url.flatMap { URL(string: $0)?.lastPathComponent } ?? "package"
        }
    }

    func validate() -> [String] {
        var problems: [String] = []
        for (i, a) in (install ?? []).enumerated() {
            if a.label.isEmpty { problems.append("Install[\(i)].Label is empty") }
            if !a.path.hasPrefix("/") { problems.append("Install[\(i)].Path should be a full path, e.g. /Applications/VLC.app") }
        }
        for r in remove ?? [] where !r.hasPrefix("/Applications/") || !r.hasSuffix(".app") || r.contains("..") {
            problems.append("Remove: \"\(r)\" should be an app in /Applications, e.g. /Applications/OneDrive.app")
        }
        for (i, p) in (packages ?? []).enumerated() {
            if (p.file == nil) == (p.url == nil) { problems.append("Packages[\(i)] needs either File or URL") }
            if p.url != nil, (p.sha256?.count ?? 0) != 64 { problems.append("Packages[\(i)]: URL needs a SHA256 (64 hex characters)") }
            if p.receipt == nil, p.app == nil || p.version == nil {
                problems.append("Packages[\(i)] needs a Receipt, or App + Version, to tell if it's installed")
            }
        }
        return problems
    }
}

/// A web link presented as an app in /Applications, e.g. Classview.
public struct WebAppConfig: Codable, Equatable, Sendable {
    public var name: String
    public var url: String
    /// App to open the link with, e.g. "Google Chrome". Default browser if omitted.
    public var browser: String?
    /// .icns file in the site resources.
    public var icon: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case url = "URL"
        case browser = "Browser"
        case icon = "Icon"
    }

    public init(name: String, url: String, browser: String? = nil, icon: String? = nil) {
        self.name = name
        self.url = url
        self.browser = browser
        self.icon = icon
    }

    func validate() -> [String] {
        var problems: [String] = []
        if name.isEmpty || name.contains("/") { problems.append("Name \"\(name)\" can't be empty or contain /") }
        if URL(string: url)?.scheme == nil { problems.append("\(name): URL \"\(url)\" is not a full URL") }
        return problems
    }
}

public struct PrintersConfig: Codable, Equatable, Sendable {
    /// The PPD every queue uses, e.g. the Apeos C6570 PPD the driver package installs (.gz is fine).
    public var ppd: String
    public var queues: [Queue]
    /// Seeded as the default for the Mac and for each user who has none. Users' own choice is kept.
    public var defaultQueue: String?
    /// Preset plist in the site resources, copied into each user's com.apple.print.custompresets once.
    public var presets: String?

    enum CodingKeys: String, CodingKey {
        case ppd = "PPD"
        case queues = "Queues"
        case defaultQueue = "Default"
        case presets = "Presets"
    }

    public init(ppd: String, queues: [Queue], defaultQueue: String? = nil, presets: String? = nil) {
        self.ppd = ppd
        self.queues = queues
        self.defaultQueue = defaultQueue
        self.presets = presets
    }

    public struct Queue: Codable, Equatable, Sendable {
        public var name: String
        public var uri: String
        public var description: String?

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case uri = "URI"
            case description = "Description"
        }

        public init(name: String, uri: String, description: String? = nil) {
            self.name = name
            self.uri = uri
            self.description = description
        }
    }

    func validate() -> [String] {
        var problems: [String] = []
        if !ppd.hasPrefix("/") { problems.append("PPD should be a full path") }
        for q in queues {
            if q.name.isEmpty || q.name.contains(where: { $0 == " " || $0 == "/" || $0 == "#" }) {
                problems.append("queue name \"\(q.name)\" can't be empty or contain spaces, / or #")
            }
            if URL(string: q.uri)?.scheme == nil { problems.append("\(q.name): URI \"\(q.uri)\" is not a full URI") }
        }
        if let d = defaultQueue, !queues.contains(where: { $0.name == d }) {
            problems.append("Default \"\(d)\" isn't one of the Queues")
        }
        return problems
    }
}

/// Background items (launchd jobs) to switch off: vendor updaters and helpers that show up under
/// System Settings > Login Items. Listed by launchd label.
public struct LoginItemsConfig: Codable, Equatable, Sendable {
    public var disable: [String]

    enum CodingKeys: String, CodingKey { case disable = "Disable" }

    public init(disable: [String]) { self.disable = disable }

    /// Never switched off, whatever the config says: Intune's own agent, Office licensing, and
    /// the Entra sign-in broker. Removing these breaks management, Office activation or sign-in.
    public static let protectedPrefixes = ["com.microsoft.intuneMDMAgent", "com.microsoft.office.licensing",
                                           "com.microsoft.entraidentitybroker", "nz.co.myers.macagent"]

    public static func isProtected(_ label: String) -> Bool {
        protectedPrefixes.contains { label.hasPrefix($0) }
    }

    func validate() -> [String] {
        disable.compactMap { label in
            if label.isEmpty || label.contains("/") { return "\"\(label)\" should be a launchd label like com.microsoft.SyncReporter" }
            if Self.isProtected(label) { return "\(label) is needed by Intune, Office or sign-in and can't be disabled" }
            return nil
        }
    }
}
