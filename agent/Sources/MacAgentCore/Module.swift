import CryptoKit
import Foundation

public enum Scope: String, CaseIterable, Sendable {
    /// Root, via the LaunchDaemon. Boot, every 4h, and when the config profile changes.
    case device
    /// The logged-in user, via the LaunchAgent, inside their GUI session. Every login.
    case session
}

public enum Enforce: String, Sendable {
    /// Apply once per subject per config hash, then leave it alone so the user can change it.
    case once
    /// Check every run and put it back if something changed it (logged as drift).
    case always
    /// Runs every time; the module tracks what it has applied itself and reports drift itself.
    /// For modules with mixed behaviour, e.g. Dock (build once, then only append new apps).
    case module
}

public enum RunResult: String, Sendable {
    /// Already as desired; nothing changed.
    case ok
    /// Applied a change (first run, or the config changed).
    case changed
    /// An `always` module found its setting changed under the same config and put it back.
    case drift
    /// Can't run yet (e.g. nobody logged in). Not a failure; retried next run.
    case waiting
    case fail

    /// Results that count as "applied" for `enforce: once`.
    var isApplied: Bool { self == .ok || self == .changed || self == .drift }
}

public enum Outcome: Equatable, Sendable {
    case ok(String)
    case changed(String)
    /// Only `enforce: module` modules return this; `always` modules get drift worked out by the runner.
    case drift(String)
    case waiting(String)
}

public struct ModuleError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// What a module gets to work with. Everything external is behind a protocol so tests can fake it.
public struct ModuleContext: Sendable {
    public var config: AgentConfig
    public var subject: String
    public var dryRun: Bool
    /// `--force`: `enforce: module` modules should re-apply from scratch.
    public var force: Bool
    public var shell: CommandRunner
    public var system: SystemInfo
    public var prefs: PreferencesStore
    public var paths: Paths
    /// Has this module applied successfully on this Mac, for the device or for any user?
    public var appliedAnywhere: @Sendable (String) -> Bool = { _ in false }
}

public protocol Module: Sendable {
    var id: String { get }
    var scope: Scope { get }
    var enforce: Enforce { get }
    /// Stable hash of the config this module depends on, or nil if the module is disabled/unconfigured.
    func configHash(_ config: AgentConfig) -> String?
    /// Bring the Mac to the desired state. `data` is the module's persistent memory; mutate to save.
    func run(_ context: ModuleContext, data: inout [String: String]) throws -> Outcome
}

public enum ConfigHash {
    /// SHA-256 over sorted-key JSON, so dictionary ordering in the plist never changes the hash.
    public static func of<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
