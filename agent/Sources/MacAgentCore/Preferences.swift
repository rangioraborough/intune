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
    func value(_ key: String, domain: String) -> Any?
    func set(_ key: String, _ value: Any?, domain: String)
    /// Flush to disk. False if cfprefsd refused the write.
    func synchronize(domain: String) -> Bool
}

public struct UserPreferences: PreferencesStore {
    public init() {}

    public func value(_ key: String, domain: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }

    public func set(_ key: String, _ value: Any?, domain: String) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain as CFString)
    }

    public func synchronize(domain: String) -> Bool {
        CFPreferencesAppSynchronize(domain as CFString)
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
