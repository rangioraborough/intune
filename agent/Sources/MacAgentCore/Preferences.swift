import CoreFoundation
import Foundation

/// Any plist value, so config can carry arbitrary preference values (bools, ints, nested dicts...).
public indirect enum PlistValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case real(Double)
    case string(String)
    case date(Date)
    case data(Data)
    case array([PlistValue])
    case dict([String: PlistValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Bool before Int: a plist <true/> must not become 1.
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .real(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Date.self) { self = .date(v) }
        else if let v = try? c.decode(Data.self) { self = .data(v) }
        else if let v = try? c.decode([PlistValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: PlistValue].self) { self = .dict(v) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported plist value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .real(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .date(let v): try c.encode(v)
        case .data(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .dict(let v): try c.encode(v)
        }
    }

    /// The Foundation object CFPreferences stores.
    public var foundationValue: Any {
        switch self {
        case .bool(let v): return NSNumber(value: v)
        case .int(let v): return NSNumber(value: v)
        case .real(let v): return NSNumber(value: v)
        case .string(let v): return v as NSString
        case .date(let v): return v as NSDate
        case .data(let v): return v as NSData
        case .array(let v): return v.map(\.foundationValue) as NSArray
        case .dict(let v): return v.mapValues(\.foundationValue) as NSDictionary
        }
    }
}

/// The current user's preferences. Session modules run as the user, so this goes through the user's
/// own cfprefsd: no `sudo -u`, no `launchctl asuser`, no "Could not write domain".
public protocol PreferencesStore: Sendable {
    /// `currentHost` is for ByHost preferences (`defaults -currentHost`), e.g. Control Center's menu bar items.
    func value(_ key: String, domain: String, currentHost: Bool) -> Any?
    func set(_ key: String, _ value: Any?, domain: String, currentHost: Bool)
    /// Top-level keys the domain has for this user.
    func keys(domain: String) -> [String]
    /// Flush to disk. False if cfprefsd refused the write.
    func synchronize(domain: String, currentHost: Bool) -> Bool
}

extension PreferencesStore {
    public func value(_ key: String, domain: String) -> Any? { value(key, domain: domain, currentHost: false) }
    public func set(_ key: String, _ value: Any?, domain: String) { set(key, value, domain: domain, currentHost: false) }
    public func synchronize(domain: String) -> Bool { synchronize(domain: domain, currentHost: false) }
}

public struct UserPreferences: PreferencesStore {
    public init() {}

    /// "NSGlobalDomain" (or ".GlobalPreferences") means preferences shared by all apps.
    static func cfDomain(_ domain: String) -> CFString {
        domain == "NSGlobalDomain" || domain == ".GlobalPreferences" ? kCFPreferencesAnyApplication : domain as CFString
    }

    static func host(_ currentHost: Bool) -> CFString { currentHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost }

    public func value(_ key: String, domain: String, currentHost: Bool) -> Any? {
        CFPreferencesCopyValue(key as CFString, Self.cfDomain(domain), kCFPreferencesCurrentUser, Self.host(currentHost))
    }

    public func set(_ key: String, _ value: Any?, domain: String, currentHost: Bool) {
        CFPreferencesSetValue(key as CFString, value as CFPropertyList?, Self.cfDomain(domain),
                              kCFPreferencesCurrentUser, Self.host(currentHost))
    }

    public func keys(domain: String) -> [String] {
        (CFPreferencesCopyKeyList(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? [String]) ?? []
    }

    public func synchronize(domain: String, currentHost: Bool) -> Bool {
        CFPreferencesSynchronize(Self.cfDomain(domain), kCFPreferencesCurrentUser, Self.host(currentHost))
    }
}

enum PlistMerge {
    /// Deep-merge `desired` into `existing`, like `defaults write -dict-add` but recursive:
    /// keys we set are replaced, keys we don't mention are kept.
    static func merge(_ desired: Any, into existing: Any?) -> Any {
        guard let want = desired as? [String: Any], let have = existing as? [String: Any] else { return desired }
        var out = have
        for (k, v) in want { out[k] = merge(v, into: have[k]) }
        return out as NSDictionary
    }

    static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a?, let b?): return (a as AnyObject).isEqual(b)
        default: return false
        }
    }
}
