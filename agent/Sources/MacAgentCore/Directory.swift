import Foundation
import OpenDirectory

public struct LocalUser: Equatable, Sendable {
    public var name: String
    public var uid: Int
    public var home: String
}

/// Local accounts, behind a protocol so modules that touch them can be tested without a real Mac.
public protocol DirectoryService: Sendable {
    /// Real people's accounts (UID 501 and up, not hidden system accounts).
    func localUsers() throws -> [LocalUser]
    func userExists(_ name: String) -> Bool
    func createAdmin(_ name: String, fullName: String) throws
    func shadowHashData(_ name: String) -> Data?
    func setShadowHashData(_ name: String, _ data: Data) throws
    func isHidden(_ name: String) -> Bool
    func setHidden(_ name: String, _ hidden: Bool) throws
    func isAdmin(_ name: String) -> Bool
    func makeAdmin(_ name: String) throws
    func hasSecureToken(_ name: String) -> Bool
    /// Path stored in the account's Picture attribute.
    func picture(_ name: String) -> String?
    func setPicture(_ name: String, path: String) throws
    /// Delete the account and its home folder.
    func deleteUser(_ name: String) throws
}

public struct LiveDirectory: DirectoryService {
    let shell: CommandRunner

    public init(shell: CommandRunner) { self.shell = shell }

    private func record(_ name: String) throws -> ODRecord {
        let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes))
        return try node.record(withRecordType: kODRecordTypeUsers, name: name, attributes: nil)
    }

    private func values(_ name: String, _ attribute: String) -> [Any] {
        (try? record(name).values(forAttribute: attribute)) ?? []
    }

    public func localUsers() throws -> [LocalUser] {
        let out = try shell.check("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"]).stdout
        return out.split(separator: "\n").compactMap { line -> LocalUser? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, let uid = Int(parts[1]), uid >= 501, !parts[0].hasPrefix("_") else { return nil }
            let name = String(parts[0])
            let home = (values(name, kODAttributeTypeNFSHomeDirectory).first as? String) ?? "/Users/\(name)"
            return LocalUser(name: name, uid: uid, home: home)
        }
    }

    public func userExists(_ name: String) -> Bool { (try? record(name)) != nil }

    public func createAdmin(_ name: String, fullName: String) throws {
        // sysadminctl needs some password; use a random one, then the real hash replaces it at once.
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let temp = Data(bytes).base64EncodedString()
        try shell.check("/usr/sbin/sysadminctl", ["-addUser", name, "-fullName", fullName, "-password", temp, "-admin"])
    }

    public func shadowHashData(_ name: String) -> Data? {
        values(name, "dsAttrTypeNative:ShadowHashData").first as? Data
    }

    public func setShadowHashData(_ name: String, _ data: Data) throws {
        let r = try record(name)
        try r.setValue(data, forAttribute: "dsAttrTypeNative:ShadowHashData")
        // The account must say its password lives in ShadowHash, PBKDF2 entry included. Keep any
        // other authorities (e.g. Kerberos) as they are.
        let authorities = values(name, kODAttributeTypeAuthenticationAuthority).compactMap { $0 as? String }
        var updated = authorities.filter { !$0.contains(";ShadowHash;") }
        updated.append(";ShadowHash;HASHLIST:<SALTED-SHA512-PBKDF2>")
        if updated != authorities { try r.setValue(updated, forAttribute: kODAttributeTypeAuthenticationAuthority) }
        try r.synchronize()
        _ = shell.run("/usr/bin/dscacheutil", ["-flushcache"])
    }

    public func isHidden(_ name: String) -> Bool {
        (values(name, "dsAttrTypeNative:IsHidden").first as? String) == "1"
    }

    public func setHidden(_ name: String, _ hidden: Bool) throws {
        try shell.check("/usr/bin/dscl", [".", "-create", "/Users/\(name)", "IsHidden", hidden ? "1" : "0"])
    }

    public func isAdmin(_ name: String) -> Bool {
        shell.run("/usr/sbin/dseditgroup", ["-o", "checkmember", "-m", name, "admin"]).succeeded
    }

    public func makeAdmin(_ name: String) throws {
        try shell.check("/usr/sbin/dseditgroup", ["-o", "edit", "-a", name, "-t", "user", "admin"])
    }

    public func hasSecureToken(_ name: String) -> Bool {
        let r = shell.run("/usr/sbin/sysadminctl", ["-secureTokenStatus", name])
        return (r.stdout + r.stderr).contains("ENABLED")
    }

    public func picture(_ name: String) -> String? {
        values(name, kODAttributeTypePicture).first as? String
    }

    public func deleteUser(_ name: String) throws {
        try shell.check("/usr/sbin/sysadminctl", ["-deleteUser", name])
    }

    public func setPicture(_ name: String, path: String) throws {
        let r = try record(name)
        // JPEGPhoto takes priority over Picture; clear it so the new picture shows.
        try? r.removeValues(forAttribute: kODAttributeTypeJPEGPhoto)
        try r.setValue(path, forAttribute: kODAttributeTypePicture)
        try r.synchronize()
    }
}
