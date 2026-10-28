import Foundation

/// Puts a teacher's name and accounting code into their Apeos print presets (the old
/// UpdatePrinterUserDetails.sh). Only keys the presets already have are replaced, so presets
/// that don't use secure print or accounting are left as they are. Passcodes are encrypted by
/// the driver and are never touched.
public enum PrinterDetails {
    static let presetsDomain = "com.apple.print.custompresets"
    static let perPrinterPrefix = "com.apple.print.custompresets.forprinter."
    static let settingsKey = "com.apple.print.preset.settings"
    static let lastUsedKey = "com.apple.print.v2.lastUsedSettingsPref"
    static let keyPrefix = "com.fujifilm.fb.jt.printsettings.ps.ap."
    static let nameKeys = ["PrintTypeUserNameReference", "PrintTypeUserNameTicketKey"]
    static let codeKeys = ["JBAUserIDTextEditReference", "JBAUserIDTextEditTicket"]

    public static func presetsInstalled(prefs: PreferencesStore) -> Bool {
        !prefs.keys(domain: presetsDomain).isEmpty
    }

    /// Per-printer preference domains, found from the user's Preferences folder.
    public static func perPrinterDomains(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let dir = home.appendingPathComponent("Library/Preferences")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(perPrinterPrefix) && $0.hasSuffix(".plist") }
            .map { String($0.dropLast(".plist".count)) }
    }

    /// Returns how many presets were updated. Empty strings mean "leave as is".
    @discardableResult
    public static func apply(name: String, code: String, prefs: PreferencesStore,
                             perPrinter: [String]? = nil) throws -> Int {
        var replacements: [String: String] = [:]
        if !name.isEmpty { for k in nameKeys { replacements[keyPrefix + k] = name } }
        if !code.isEmpty { for k in codeKeys { replacements[keyPrefix + k] = code } }
        guard !replacements.isEmpty else { return 0 }

        func replace(in dict: [String: Any]) -> [String: Any]? {
            var out = dict
            var changed = false
            for (k, v) in replacements where out[k] != nil {
                out[k] = v
                changed = true
            }
            return changed ? out : nil
        }

        var updated = 0
        for preset in prefs.keys(domain: presetsDomain) {
            guard var dict = prefs.value(preset, domain: presetsDomain) as? [String: Any],
                  let settings = dict[settingsKey] as? [String: Any],
                  let newSettings = replace(in: settings) else { continue }
            dict[settingsKey] = newSettings
            prefs.set(preset, dict as NSDictionary, domain: presetsDomain)
            updated += 1
        }
        guard prefs.synchronize(domain: presetsDomain) else { throw ModuleError("could not save print presets") }

        // Each printer also remembers its last-used settings, which the print dialog starts from.
        for domain in perPrinter ?? perPrinterDomains() {
            guard let last = prefs.value(lastUsedKey, domain: domain) as? [String: Any],
                  let newLast = replace(in: last) else { continue }
            prefs.set(lastUsedKey, newLast as NSDictionary, domain: domain)
            _ = prefs.synchronize(domain: domain)
        }
        return updated
    }
}
