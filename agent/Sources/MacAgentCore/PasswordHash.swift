import CommonCrypto
import Foundation
import Security

/// A macOS account password in the form macOS stores it (ShadowHashData SALTED-SHA512-PBKDF2),
/// carried in config as `pbkdf2-sha512$<iterations>$<salt b64>$<entropy b64>`.
/// The agent writes it straight onto the account, so the plain-text password never exists on a Mac.
public struct PasswordHash: Equatable, Sendable {
    public var iterations: Int
    public var salt: Data
    public var entropy: Data

    static let prefix = "pbkdf2-sha512"

    public init(iterations: Int, salt: Data, entropy: Data) {
        self.iterations = iterations
        self.salt = salt
        self.entropy = entropy
    }

    public init?(string: String) {
        let parts = string.split(separator: "$", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == Self.prefix, let iterations = Int(parts[1]), iterations >= 10_000,
              let salt = Data(base64Encoded: parts[2]), salt.count >= 16,
              let entropy = Data(base64Encoded: parts[3]), entropy.count == 128 else { return nil }
        self.init(iterations: iterations, salt: salt, entropy: entropy)
    }

    public var string: String {
        "\(Self.prefix)$\(iterations)$\(salt.base64EncodedString())$\(entropy.base64EncodedString())"
    }

    /// Hash a password with a fresh random salt.
    public static func make(password: String, iterations: Int = 250_000) -> PasswordHash {
        var salt = Data(count: 32)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return PasswordHash(iterations: iterations, salt: salt,
                            entropy: derive(password: password, salt: salt, iterations: iterations))
    }

    public func matches(password: String) -> Bool {
        Self.derive(password: password, salt: salt, iterations: iterations) == entropy
    }

    static func derive(password: String, salt: Data, iterations: Int) -> Data {
        var out = Data(count: 128)
        let pw = Array(password.utf8).map { Int8(bitPattern: $0) }
        _ = out.withUnsafeMutableBytes { outBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), UInt32(iterations),
                                     outBytes.bindMemory(to: UInt8.self).baseAddress, 128)
            }
        }
        return out
    }

    static let shadowKey = "SALTED-SHA512-PBKDF2"

    /// The binary plist macOS keeps in the account's ShadowHashData attribute.
    public var shadowHashData: Data {
        let dict: [String: Any] = [Self.shadowKey: ["entropy": entropy, "salt": salt, "iterations": iterations]]
        return (try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)) ?? Data()
    }

    /// Read the PBKDF2 entry back out of an account's ShadowHashData, if it has one.
    public init?(shadowHashData data: Data) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entry = plist[Self.shadowKey] as? [String: Any],
              let entropy = entry["entropy"] as? Data, let salt = entry["salt"] as? Data,
              let iterations = (entry["iterations"] as? NSNumber)?.intValue else { return nil }
        self.init(iterations: iterations, salt: salt, entropy: entropy)
    }
}
