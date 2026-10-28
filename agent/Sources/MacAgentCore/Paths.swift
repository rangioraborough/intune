import Foundation

public enum AgentVersion {
    /// Single source of truth for the agent version. build.sh reads this line.
    public static let current = "0.2.0"
}

public enum AgentIdentity {
    public static let bundleID = "nz.co.myers.macagent"
    public static let daemonLabel = "nz.co.myers.macagent.daemon"
    public static let sessionLabel = "nz.co.myers.macagent.session"
    /// One app in /Applications: the menu bar app is its main executable; the CLI sits beside it.
    public static let appPath = "/Applications/MacAgent.app"
    public static let cliPath = appPath + "/Contents/MacOS/macagent"
}

/// Every filesystem location the agent touches. Injected so tests can point it at a temp dir.
public struct Paths: Sendable {
    /// Intune-delivered config (Preference file payload).
    public var managedConfig: URL
    /// Last config that passed validation, used if the managed one is missing or broken.
    public var configCache: URL
    /// Site resources installed by the per-school resources package.
    public var siteResources: URL
    public var stateDB: URL
    public var log: URL
    public var lock: URL
    /// Filesystem root for absolute paths modules touch directly ("/" in production, a temp dir in tests).
    public var root: URL = URL(fileURLWithPath: "/")
    /// Where users' home folders live, for reading each user's session state.
    public var usersDir: URL = URL(fileURLWithPath: "/Users")
    /// Archived logs from the old Intune scripts.
    public var legacyArchive: URL = URL(fileURLWithPath: "/Library/Logs/MacAgent/legacy")

    /// An absolute path such as /Library/LaunchDaemons/x.plist, resolved against `root`.
    public func resolve(_ absolute: String) -> URL {
        root.appendingPathComponent(String(absolute.drop(while: { $0 == "/" })))
    }

    public static func device() -> Paths {
        let support = URL(fileURLWithPath: "/Library/Application Support/MacAgent")
        return Paths(
            managedConfig: URL(fileURLWithPath: "/Library/Managed Preferences/\(AgentIdentity.bundleID).plist"),
            configCache: support.appendingPathComponent("config-cache.plist"),
            siteResources: support.appendingPathComponent("Site"),
            stateDB: support.appendingPathComponent("state.db"),
            log: URL(fileURLWithPath: "/Library/Logs/MacAgent/agent.log"),
            lock: support.appendingPathComponent("device.lock")
        )
    }

    /// Session runs read config from the same places as the daemon but keep their own state and log.
    public static func session(home: URL) -> Paths {
        var p = device()
        let support = home.appendingPathComponent("Library/Application Support/MacAgent")
        p.stateDB = support.appendingPathComponent("state.db")
        p.log = home.appendingPathComponent("Library/Logs/MacAgent/session.log")
        p.lock = support.appendingPathComponent("session.lock")
        return p
    }
}
