import Foundation
import MacAgentCore
import Security

/// The files the console hands out: the agent pkg, the school's site pkg and the config plist.
/// Macs ask for them by SHA-256, so a request always gets exactly the file it was signed for.
struct LibraryFile: Equatable {
    let target: FleetAction.Target
    let path: String
    let sha256: String
    let version: String?

    var name: String { (path as NSString).lastPathComponent }

    static func load(_ target: FleetAction.Target, path: String) -> LibraryFile? {
        guard !path.isEmpty, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return LibraryFile(target: target, path: path, sha256: FleetWire.sha256(data), version: version(of: path, target, data))
    }

    /// Agent/site versions come from the file name (MacAgent-0.3.0.pkg, "MacAgent Site - RBS-1.2.0.pkg");
    /// the config's from its ConfigVersion.
    static func version(of path: String, _ target: FleetAction.Target, _ data: Data) -> String? {
        if target == .config, case .success(let c) = ConfigLoader.decode(data: data, source: path) { return String(c.configVersion) }
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return base.split(separator: "-").last.map(String.init)
    }
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var files: [FleetAction.Target: LibraryFile] = [:]

    static let repo = "/Users/sysadmin/Projects/Github/rangioraborough/intune"
    static let defaults: [FleetAction.Target: String] = [
        .config: repo + "/agent/config/rbs.plist",
    ]

    init() { reload() }

    func path(_ t: FleetAction.Target) -> String {
        UserDefaults.standard.string(forKey: "library.\(t.rawValue)") ?? Self.defaults[t] ?? Self.newest(t) ?? ""
    }

    func setPath(_ t: FleetAction.Target, _ path: String) {
        UserDefaults.standard.set(path, forKey: "library.\(t.rawValue)")
        reload()
    }

    func reload() {
        var f: [FleetAction.Target: LibraryFile] = [:]
        for t in [FleetAction.Target.agent, .site, .config] { f[t] = LibraryFile.load(t, path: path(t)) }
        files = f
    }

    func file(sha256: String) -> LibraryFile? { files.values.first { $0.sha256 == sha256 } }

    /// Newest build in the repo's dist folders, so a fresh console works without setup.
    static func newest(_ t: FleetAction.Target) -> String? {
        let (dir, prefix) = t == .agent ? (repo + "/agent/dist", "MacAgent-") : (repo + "/site/dist", "MacAgent Site - ")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".pkg") }
        return names.max { $0.localizedStandardCompare($1) == .orderedAscending }.map { dir + "/" + $0 }
    }
}

/// The default password for installing on a new Mac (the user's own account, e.g. "school"),
/// kept in this Mac's login Keychain.
enum InstallPassword {
    static let service = "MacAgent Console", account = "default-install-password"

    static func load() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func save(_ password: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

extension String {
    /// Numeric version compare, so 0.10.0 is newer than 0.3.0.
    func isOlder(than other: String) -> Bool { compare(other, options: .numeric) == .orderedAscending }
}
