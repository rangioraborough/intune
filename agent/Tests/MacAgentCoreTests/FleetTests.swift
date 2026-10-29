import CryptoKit
import Foundation
import Testing
@testable import MacAgentCore

@Suite struct FleetTests {
    let consoleKey = Curve25519.Signing.PrivateKey()
    let fleetKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    var console: ConsoleConfig {
        ConsoleConfig(url: "http://127.0.0.1:1", fleetKey: fleetKey, publicKey: consoleKey.publicKey.rawRepresentation.base64EncodedString())
    }

    func action(_ kind: FleetAction.Kind = .run, serial: String = "SERIAL1", module: String? = nil,
                expires: TimeInterval = 3600, key: Curve25519.Signing.PrivateKey? = nil) throws -> FleetAction {
        try FleetAction(id: UUID().uuidString, serial: serial, kind: kind, module: module,
                        issued: Date(), expires: Date(timeIntervalSinceNow: expires)).signed(with: key ?? consoleKey)
    }

    @Test func actionsMustBeSignedByOurConsoleForThisMacAndFresh() throws {
        let pub = console.publicKey
        try action().verify(publicKey: pub, serial: "SERIAL1")
        #expect(throws: FleetAction.Rejection.badSignature) {
            try action(key: Curve25519.Signing.PrivateKey()).verify(publicKey: pub, serial: "SERIAL1")
        }
        #expect(throws: FleetAction.Rejection.wrongMac) { try action(serial: "OTHER").verify(publicKey: pub, serial: "SERIAL1") }
        #expect(throws: FleetAction.Rejection.expired) { try action(expires: -1).verify(publicKey: pub, serial: "SERIAL1") }
        var tampered = try action(.run)
        tampered.kind = .reapply   // change after signing
        #expect(throws: FleetAction.Rejection.badSignature) { try tampered.verify(publicKey: pub, serial: "SERIAL1") }
    }

    @Test func installDetailsAreSignedButOldPayloadsUnchanged() throws {
        let run = FleetAction(id: "a", serial: "S", kind: .run, module: nil, issued: Date(timeIntervalSince1970: 1), expires: Date(timeIntervalSince1970: 2))
        #expect(String(decoding: run.payload, as: UTF8.self) == "macagent-action-v1|a|S|run||1|2")   // what 0.2 agents verify
        var install = try FleetAction(id: "b", serial: "SERIAL1", kind: .install, module: nil, issued: Date(),
                                      expires: Date(timeIntervalSinceNow: 60), target: .agent, sha256: String(repeating: "a", count: 64)).signed(with: consoleKey)
        try install.verify(publicKey: console.publicKey, serial: "SERIAL1")
        install.sha256 = String(repeating: "b", count: 64)   // swap the file after signing
        #expect(throws: FleetAction.Rejection.badSignature) { try install.verify(publicKey: console.publicKey, serial: "SERIAL1") }
    }

    @Test func reportSignatureDetectsTampering() throws {
        let body = Data("{\"serial\":\"A\"}".utf8)
        let sig = try #require(FleetWire.sign(body, fleetKey: fleetKey))
        #expect(FleetWire.verify(body, signature: sig, fleetKey: fleetKey))
        #expect(!FleetWire.verify(Data("{\"serial\":\"B\"}".utf8), signature: sig, fleetKey: fleetKey))
    }

    @Test func handlesEachActionOnceAndRefusesBadOnes() throws {
        let dir = tempDir()
        let p = testPaths(dir)
        try FileManager.default.createDirectory(at: p.configCache.deletingLastPathComponent(), withIntermediateDirectories: true)
        let reporter = FleetReporter(console: console, paths: p, shell: FakeShell(), system: FakeSystem())
        let good = try action(.reapply, module: "dock")
        let forged = try action(key: Curve25519.Signing.PrivateKey())
        let results = reporter.handle([good, forged], serial: "SERIAL1")
        #expect(results.map(\.ok) == [true, false])
        #expect(FleetRequests.load(p).reapply["dock"] != nil)
        #expect(reporter.handle([good], serial: "SERIAL1").isEmpty)   // not run twice
    }

    @Test func reapplyForcesOnlyModulesRequestedSinceTheyRan() throws {
        let store = try StateStore(url: tempDir().appendingPathComponent("s.db"))
        try store.put(ModuleState(module: "dock", subject: "kim", configHash: "h", lastRun: Date(timeIntervalSinceNow: -60),
                                  result: .ok, duration: 0, detail: "", agentVersion: "t", data: [:]))
        try store.put(ModuleState(module: "wallpaper", subject: "kim", configHash: "h", lastRun: Date(),
                                  result: .ok, duration: 0, detail: "", agentVersion: "t", data: [:]))
        let requests = FleetRequests(reapply: ["dock": Date(timeIntervalSinceNow: -30), "wallpaper": Date(timeIntervalSinceNow: -30)])
        #expect(requests.modulesToForce(state: store, subject: "kim") == ["dock"])
    }

    @Test func consoleConfigValidation() {
        #expect(console.validate().isEmpty)
        #expect(ConsoleConfig(url: "nope", fleetKey: "x", publicKey: "y").validate().count == 3)
    }
}
