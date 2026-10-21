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

    func consoleUser() -> String? { user }
    func hardware() throws -> HardwareInfo { hw }
    func fileExists(_ path: String) -> Bool { files.contains(path) }
}

/// In-memory preferences, with a switch to simulate cfprefsd refusing writes.
final class FakePrefs: PreferencesStore, @unchecked Sendable {
    var domains: [String: [String: Any]] = [:]
    var refuseSync = false
    private(set) var syncs: [String] = []

    func value(_ key: String, domain: String) -> Any? { domains[domain]?[key] }
    func set(_ key: String, _ value: Any?, domain: String) { domains[domain, default: [:]][key] = value }
    func synchronize(domain: String) -> Bool { syncs.append(domain); return !refuseSync }
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
