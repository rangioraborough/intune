import CryptoKit
import Foundation

/// Where Macs report to: the MacAgent Console app on an IT Mac. Reports are signed with the fleet
/// key (HMAC); actions coming back are signed by the console's private key and checked against
/// `PublicKey` here, so only that console can ask Macs to do anything, and only agent actions.
public struct ConsoleConfig: Codable, Equatable, Sendable {
    /// e.g. http://10.46.0.93:8730
    public var url: String
    /// Base64, 32 bytes. Signs reports so stray devices can't post fake status.
    public var fleetKey: String
    /// Base64 Curve25519 signing public key of the console.
    public var publicKey: String

    enum CodingKeys: String, CodingKey {
        case url = "URL"
        case fleetKey = "FleetKey"
        case publicKey = "PublicKey"
    }

    public init(url: String, fleetKey: String, publicKey: String) {
        self.url = url
        self.fleetKey = fleetKey
        self.publicKey = publicKey
    }

    func validate() -> [String] {
        var problems: [String] = []
        if URL(string: url)?.scheme == nil { problems.append("URL \"\(url)\" is not a full URL") }
        if Data(base64Encoded: fleetKey)?.count != 32 { problems.append("FleetKey should be 32 bytes, base64 (copy it from the console's Setup)") }
        if (try? Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: publicKey) ?? Data())) == nil {
            problems.append("PublicKey isn't a valid key (copy it from the console's Setup)")
        }
        return problems
    }
}

/// What a Mac sends the console.
public struct FleetReport: Codable, Equatable, Sendable {
    public struct State: Codable, Equatable, Sendable {
        public var subject: String
        public var module: String
        public var result: String
        public var detail: String
        public var lastRun: Date

        public init(subject: String, module: String, result: String, detail: String, lastRun: Date) {
            self.subject = subject
            self.module = module
            self.result = result
            self.detail = detail
            self.lastRun = lastRun
        }
    }

    public struct ActionResult: Codable, Equatable, Sendable {
        public var id: String
        public var ok: Bool
        public var detail: String

        public init(id: String, ok: Bool, detail: String) {
            self.id = id
            self.ok = ok
            self.detail = detail
        }
    }

    public var serial: String
    public var computerName: String
    public var model: String
    public var macOS: String
    public var agentVersion: String
    public var consoleUser: String?
    public var officeVersion: String?
    public var configVersion: Int?
    public var ipAddress: String?
    public var sentAt: Date
    public var states: [State]
    public var actionResults: [ActionResult]

    public init(serial: String, computerName: String, model: String, macOS: String, agentVersion: String,
                consoleUser: String?, officeVersion: String?, configVersion: Int?, ipAddress: String?,
                sentAt: Date, states: [State], actionResults: [ActionResult]) {
        self.serial = serial
        self.computerName = computerName
        self.model = model
        self.macOS = macOS
        self.agentVersion = agentVersion
        self.consoleUser = consoleUser
        self.officeVersion = officeVersion
        self.configVersion = configVersion
        self.ipAddress = ipAddress
        self.sentAt = sentAt
        self.states = states
        self.actionResults = actionResults
    }

    public var failures: [State] { states.filter { $0.result == RunResult.fail.rawValue } }
}

/// A request from the console. Only agent actions exist; there is no way to run arbitrary commands.
public struct FleetAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Run the device modules now (and then the logged-in user's session).
        case run
        /// Forget a module's state everywhere (device and every user) so it applies again, then run.
        case reapply
        /// Download a file from the console (agent pkg, site pkg or config), check its SHA-256, install it.
        case install
    }

    /// What `install` installs.
    public enum Target: String, Codable, Sendable { case agent, site, config }

    public var id: String
    public var serial: String
    public var kind: Kind
    public var module: String?
    public var issued: Date
    public var expires: Date
    /// For `install`: what to install, and the SHA-256 the download must match (signed, so the
    /// console can't be tricked into handing over a different file).
    public var target: Target?
    public var sha256: String?
    /// Base64 Curve25519 signature over `payload`.
    public var signature: String

    public init(id: String, serial: String, kind: Kind, module: String?, issued: Date, expires: Date,
                target: Target? = nil, sha256: String? = nil, signature: String = "") {
        self.id = id
        self.serial = serial
        self.kind = kind
        self.module = module
        self.issued = issued
        self.expires = expires
        self.target = target
        self.sha256 = sha256
        self.signature = signature
    }

    /// The exact bytes the console signs. Install details are appended only when present, so
    /// run/reapply payloads stay identical to what older agents verify.
    public var payload: Data {
        var s = "macagent-action-v1|\(id)|\(serial)|\(kind.rawValue)|\(module ?? "")|\(Int(issued.timeIntervalSince1970))|\(Int(expires.timeIntervalSince1970))"
        if target != nil || sha256 != nil { s += "|\(target?.rawValue ?? "")|\(sha256 ?? "")" }
        return Data(s.utf8)
    }

    public func signed(with key: Curve25519.Signing.PrivateKey) throws -> FleetAction {
        var copy = self
        copy.signature = try key.signature(for: payload).base64EncodedString()
        return copy
    }

    public enum Rejection: Error, Equatable { case badSignature, wrongMac, expired }

    /// Check an action before acting on it: signed by our console, for this Mac, not expired.
    public func verify(publicKey: String, serial mySerial: String, now: Date = Date()) throws {
        guard let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              let sig = Data(base64Encoded: signature),
              key.isValidSignature(sig, for: payload) else { throw Rejection.badSignature }
        guard serial == mySerial else { throw Rejection.wrongMac }
        guard now < expires else { throw Rejection.expired }
    }
}

public struct FleetResponse: Codable, Equatable, Sendable {
    public var actions: [FleetAction]
    public init(actions: [FleetAction]) { self.actions = actions }
}

public enum FleetWire {
    public static let signatureHeader = "X-MacAgent-Signature"

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// HMAC-SHA256 of the request body with the fleet key, base64.
    public static func sign(_ body: Data, fleetKey: String) -> String? {
        guard let k = Data(base64Encoded: fleetKey) else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: k))
        return Data(mac).base64EncodedString()
    }

    /// Path a Mac downloads an install file from; requests are signed (HMAC of the path) because the
    /// config holds the fleet key and password hash.
    public static func filePath(_ sha256: String) -> String { "/api/file/\(sha256)" }
    /// Long-poll path for a Mac's requests (signed like file requests).
    public static func waitPath(_ serial: String) -> String { "/api/wait/\(serial)" }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ body: Data, signature: String, fleetKey: String) -> Bool {
        guard let k = Data(base64Encoded: fleetKey), let sig = Data(base64Encoded: signature) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(sig, authenticating: body, using: SymmetricKey(data: k))
    }
}
