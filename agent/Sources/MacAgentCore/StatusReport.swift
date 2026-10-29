import Foundation

/// A plain-language view of this Mac's state for one user: the device's modules plus theirs.
/// Shared by the menu bar app and anything else that shows status to people.
public struct StatusReport: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public var module: String
        public var title: String
        public var result: RunResult
        public var detail: String
        public var lastRun: Date
    }

    public var rows: [Row]
    public var lastChecked: Date?

    public var problems: [Row] { rows.filter { $0.result == .fail } }
    public var healthy: Bool { problems.isEmpty }

    /// Friendly names; modules not listed here (internal housekeeping) aren't shown to users.
    static let titles: [String: String] = [
        "device-name": "Computer name",
        "preferences": "Finder & settings",
        "dock": "Dock",
        "admin-account": "IT admin account",
        "apps": "Apps",
        "printer-queues": "Printers",
        "printer-presets": "Printer settings",
        "wallpaper": "Wallpaper",
        "avatar": "Account picture",
        "default-browser": "Default browser",
        "mau-disable": "Office updates",
        "web-apps": "Web apps",
        "login-items": "Background items",
        "login-items-user": "Background items (yours)",
    ]

    public init(states: [ModuleState]) {
        rows = states.compactMap { s in
            guard let title = Self.titles[s.module] else { return nil }
            return Row(module: s.module, title: title, result: s.result, detail: s.detail, lastRun: s.lastRun)
        }.sorted { $0.title < $1.title }
        lastChecked = states.map(\.lastRun).max()
    }

    /// Device state plus the given user's session state, read-only.
    public static func load(home: URL) -> StatusReport {
        var states: [ModuleState] = []
        for url in [Paths.device().stateDB, Paths.session(home: home).stateDB]
        where FileManager.default.isReadableFile(atPath: url.path) {
            if let store = try? StateStore(url: url, readOnly: true) { states += store.all() }
        }
        return StatusReport(states: states)
    }

    /// "MacAgent 0.3.1 · No issues": which agent this is, and whether anything needs attention.
    public var headline: String { "MacAgent \(AgentVersion.current) · \(issueSummary)" }

    public var issueSummary: String {
        if rows.isEmpty { return "Waiting for first check" }
        switch problems.count {
        case 0: return "No issues"
        case 1: return "1 issue"
        default: return "\(problems.count) issues"
        }
    }

    /// Text for "Copy diagnostics": everything IT needs in a ticket.
    public func diagnostics(computerName: String, user: String, version: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = ["MacAgent \(version) on \(computerName), user \(user)",
                     "Last checked: \(lastChecked.map(f.string) ?? "never")", ""]
        for r in rows {
            lines.append("\(r.result.rawValue.uppercased().padding(toLength: 8, withPad: " ", startingAt: 0)) "
                         + "\(r.title): \(r.detail) (\(f.string(from: r.lastRun)))")
        }
        return lines.joined(separator: "\n")
    }
}

/// How the menu bar app asks the root daemon for a run: it touches a per-user file in a folder the
/// daemon's LaunchDaemon watches. All it can do is start a normal run (launchd throttles to 1/min).
public enum RunTrigger {
    public static let directory = URL(fileURLWithPath: "/Library/Application Support/MacAgent/Trigger")

    public static func request(user: String) throws {
        let file = directory.appendingPathComponent(user)
        try Data(ISO8601DateFormatter().string(from: Date()).utf8).write(to: file)
    }
}
