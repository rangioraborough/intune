import Foundation
@testable import MacAgentCore

/// Records every command and answers from a table keyed by "executable arg1 arg2 ...".
final class FakeShell: CommandRunner, @unchecked Sendable {
    var responses: [String: CommandResult] = [:]
    private(set) var calls: [String] = []
    private let lock = NSLock()

    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let key = ([executable] + arguments).joined(separator: " ")
        lock.lock(); defer { lock.unlock() }
        calls.append(key)
        return responses[key] ?? CommandResult(exitCode: 0)
    }

    var setCalls: [String] { calls.filter { $0.contains("--set") } }
}

/// A fake `scutil` that remembers what was set, so a second run sees the new names.
final class FakeScutil: CommandRunner, @unchecked Sendable {
    var names: [String: String]
    private(set) var sets: [String] = []

    init(_ names: [String: String]) { self.names = names }

    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        guard executable == "/usr/sbin/scutil", arguments.count >= 2 else { return CommandResult(exitCode: 0) }
        if arguments[0] == "--get" {
            guard let v = names[arguments[1]] else { return CommandResult(exitCode: 1, stderr: "not set") }
            return CommandResult(exitCode: 0, stdout: v + "\n")
        }
        if arguments[0] == "--set", arguments.count == 3 {
            names[arguments[1]] = arguments[2]
            sets.append("\(arguments[1])=\(arguments[2])")
        }
        return CommandResult(exitCode: 0)
    }
}

struct FakeSystem: SystemInfo {
    var user: String?
    var hw = HardwareInfo(modelName: "MacBook Air", serial: "C02TEST123")
    var files: Set<String> = []
    var fullNames: [String: String] = [:]

    func consoleUser() -> String? { user }
    func hardware() throws -> HardwareInfo { hw }
    func fileExists(_ path: String) -> Bool { files.contains(path) }
    func fullName(of user: String) -> String? { fullNames[user] }
    func appVersion(_ path: String) -> String? { nil }
    func modified(_ path: String) -> Date? { nil }
}

/// In-memory preferences, with a switch to simulate cfprefsd refusing writes.
final class FakePrefs: PreferencesStore, @unchecked Sendable {
    var domains: [String: [String: Any]] = [:]
    var refuseSync = false
    private(set) var syncs: [String] = []

    static func key(_ domain: String, _ currentHost: Bool) -> String { currentHost ? "byhost:" + domain : domain }
    func value(_ key: String, domain: String, currentHost: Bool) -> Any? { domains[Self.key(domain, currentHost)]?[key] }
    func set(_ key: String, _ value: Any?, domain: String, currentHost: Bool) { domains[Self.key(domain, currentHost), default: [:]][key] = value }
    func keys(domain: String) -> [String] { Array((domains[domain] ?? [:]).keys) }
    func synchronize(domain: String, currentHost: Bool) -> Bool { syncs.append(Self.key(domain, currentHost)); return !refuseSync }
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("macagent-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func testPaths(_ dir: URL) -> Paths {
    var p = Paths(managedConfig: dir.appendingPathComponent("managed.plist"),
                  configCache: dir.appendingPathComponent("cache.plist"),
                  siteResources: dir.appendingPathComponent("Site"),
                  stateDB: dir.appendingPathComponent("state.db"),
                  log: dir.appendingPathComponent("agent.log"),
                  lock: dir.appendingPathComponent("lock"))
    p.root = dir.appendingPathComponent("root")
    p.usersDir = dir.appendingPathComponent("root/Users")
    p.legacyArchive = dir.appendingPathComponent("root/Library/Logs/MacAgent/legacy")
    return p
}

/// Create a file (and its folders) under the test root.
func touch(_ p: Paths, _ absolute: String) {
    let url = p.resolve(absolute)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data().write(to: url)
}

func makeRunner(_ dir: URL, shell: CommandRunner, system: SystemInfo, prefs: PreferencesStore = FakePrefs(),
                modules: [Module] = ModuleRegistry.all) throws -> Runner {
    let p = testPaths(dir)
    return Runner(modules: modules, state: try StateStore(url: p.stateDB), log: AgentLog(url: p.log),
                  shell: shell, system: system, prefs: prefs, paths: p)
}

final class FakeDirectory: DirectoryService, @unchecked Sendable {
    struct Account { var shadow: Data?; var hidden = false; var admin = false; var token = false; var picture: String? }
    var accounts: [String: Account] = [:]
    var uids: [String: Int] = [:]
    private(set) var created: [String] = []

    func localUsers() throws -> [LocalUser] {
        accounts.keys.sorted().map { LocalUser(name: $0, uid: uids[$0] ?? 501, home: "/Users/\($0)") }
    }
    func userExists(_ name: String) -> Bool { accounts[name] != nil }
    func createAdmin(_ name: String, fullName: String) throws { created.append(name); accounts[name] = Account(shadow: nil, admin: true) }
    func shadowHashData(_ name: String) -> Data? { accounts[name]?.shadow }
    func setShadowHashData(_ name: String, _ data: Data) throws { accounts[name]?.shadow = data }
    func isHidden(_ name: String) -> Bool { accounts[name]?.hidden ?? false }
    func setHidden(_ name: String, _ hidden: Bool) throws { accounts[name]?.hidden = hidden }
    func isAdmin(_ name: String) -> Bool { accounts[name]?.admin ?? false }
    func makeAdmin(_ name: String) throws { accounts[name]?.admin = true }
    func hasSecureToken(_ name: String) -> Bool { accounts[name]?.token ?? false }
    func picture(_ name: String) -> String? { accounts[name]?.picture }
    func setPicture(_ name: String, path: String) throws { accounts[name]?.picture = path }
    func deleteUser(_ name: String) throws { accounts[name] = nil }
}

final class FakeDesktop: Desktop, @unchecked Sendable {
    var current: URL?
    var browser: URL?
    var answer: BrowserAnswer = .agreed
    private(set) var asked = 0

    func wallpaper() -> URL? { current }
    func setWallpaper(_ url: URL) throws { current = url }
    func defaultBrowser() -> URL? { browser }
    func requestDefaultBrowser(_ app: URL) -> BrowserAnswer {
        asked += 1
        if answer == .agreed { browser = app }
        return answer
    }
}

/// A SystemInfo whose files can change mid-test (e.g. an installer "creating" an app).
final class MutableSystem: SystemInfo, @unchecked Sendable {
    var files: Set<String>
    var user: String?
    init(files: Set<String> = [], user: String? = nil) { self.files = files; self.user = user }
    func consoleUser() -> String? { user }
    func hardware() throws -> HardwareInfo { HardwareInfo(modelName: "MacBook Air", serial: "X") }
    func fileExists(_ path: String) -> Bool { files.contains(path) }
    func fullName(of user: String) -> String? { nil }
    var versions: [String: String] = [:]
    var modifiedDates: [String: Date] = [:]
    func appVersion(_ path: String) -> String? { versions[path] }
    func modified(_ path: String) -> Date? { modifiedDates[path] }
}

/// A shell where a command can have a side effect, e.g. Installomator creating the app.
final class ScriptedShell: CommandRunner, @unchecked Sendable {
    var handler: (String) -> CommandResult
    private(set) var calls: [String] = []
    init(_ handler: @escaping (String) -> CommandResult = { _ in CommandResult(exitCode: 0) }) { self.handler = handler }
    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let key = ([executable] + arguments).joined(separator: " ")
        calls.append(key)
        return handler(key)
    }
}
