import CryptoKit
import Foundation
import MacAgentCore
import SwiftUI

/// The console's data: its keys, the latest report from each Mac, and queued actions.
/// Kept in ~/Library/Application Support/MacAgent Console as JSON (keys file is owner-only).
@MainActor
final class ConsoleStore: ObservableObject {
    struct Device: Codable, Identifiable {
        var report: FleetReport
        var lastSeen: Date
        var id: String { report.serial }
    }

    struct QueuedAction: Codable, Identifiable {
        var action: FleetAction
        var label: String
        var result: FleetReport.ActionResult?
        var id: String { action.id }
    }

    struct Keys: Codable {
        var fleetKey: String
        var signingKey: String
    }

    @Published private(set) var devices: [String: Device] = [:]
    @Published private(set) var actions: [QueuedAction] = []
    @Published var serverStatus = "Starting…"
    let keys: Keys
    /// Called with a Mac's serial when a request is queued for it (the server wakes its long-poll).
    var onQueue: ((String) -> Void)?

    static let port: UInt16 = 8730
    static let quietAfter: TimeInterval = 2 * 3600

    private let dir: URL

    init() {
        dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacAgent Console")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keysURL = dir.appendingPathComponent("keys.json")
        if let data = try? Data(contentsOf: keysURL), let k = try? JSONDecoder().decode(Keys.self, from: data) {
            keys = k
        } else {
            let fleet = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
            keys = Keys(fleetKey: fleet, signingKey: Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())
            try? JSONEncoder().encode(keys).write(to: keysURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysURL.path)
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("fleet.json")),
           let saved = try? FleetWire.decoder().decode([String: Device].self, from: data) { devices = saved }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("actions.json")),
           let saved = try? FleetWire.decoder().decode([QueuedAction].self, from: data) { actions = saved }
    }

    var publicKey: String {
        (try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: keys.signingKey) ?? Data()))?
            .publicKey.rawRepresentation.base64EncodedString() ?? ""
    }

    var sortedDevices: [Device] {
        devices.values.sorted { $0.report.computerName.localizedStandardCompare($1.report.computerName) == .orderedAscending }
    }

    func isQuiet(_ d: Device) -> Bool { Date().timeIntervalSince(d.lastSeen) > Self.quietAfter }

    // MARK: Reports in, actions out

    /// Store a verified report; returns the actions still waiting for that Mac.
    func receive(_ report: FleetReport) -> [FleetAction] {
        devices[report.serial] = Device(report: report, lastSeen: Date())
        for r in report.actionResults {
            if let i = actions.firstIndex(where: { $0.id == r.id }) { actions[i].result = r }
        }
        save()
        return pending(for: report.serial)
    }

    func pending(for serial: String) -> [FleetAction] {
        actions.filter { $0.action.serial == serial && $0.result == nil && $0.action.expires > Date() }.map(\.action)
    }

    /// A waiting Mac counts as seen (it's online), even between its 10-minute reports.
    func markSeen(_ serial: String) {
        guard devices[serial] != nil else { return }
        devices[serial]?.lastSeen = Date()
    }

    func queue(_ kind: FleetAction.Kind, module: String? = nil, file: LibraryFile? = nil, for serial: String, label: String) {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: keys.signingKey) ?? Data()),
              let signed = try? FleetAction(id: UUID().uuidString, serial: serial, kind: kind, module: module,
                                            issued: Date(), expires: Date(timeIntervalSinceNow: 24 * 3600),
                                            target: file?.target, sha256: file?.sha256).signed(with: key)
        else { return }
        actions.append(QueuedAction(action: signed, label: label))
        save()
        onQueue?(serial)
    }

    func actions(for serial: String) -> [QueuedAction] {
        actions.filter { $0.action.serial == serial }.sorted { $0.action.issued > $1.action.issued }
    }

    func forget(_ serial: String) {
        devices[serial] = nil
        actions.removeAll { $0.action.serial == serial }
        save()
    }

    private func save() {
        actions = Array(actions.suffix(500))
        try? FleetWire.encoder().encode(devices).write(to: dir.appendingPathComponent("fleet.json"), options: .atomic)
        try? FleetWire.encoder().encode(actions).write(to: dir.appendingPathComponent("actions.json"), options: .atomic)
    }

    /// What to paste into the Intune config (the Console dict).
    func configSnippet(url: String) -> String {
        """
        <key>Console</key>
        <dict>
            <key>URL</key>
            <string>\(url)</string>
            <key>FleetKey</key>
            <string>\(keys.fleetKey)</string>
            <key>PublicKey</key>
            <string>\(publicKey)</string>
        </dict>
        """
    }
}
