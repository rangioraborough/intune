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

    @Test func parsesInstalledPrinters() {
        let list = FleetReporter.parsePrinters(
            devices: "device for Ruru_Copier: lpd://10.69.192.23\ndevice for Tony_s_Printer: dnssd://x\n",
            defaultLine: "system default destination: Ruru_Copier\n",
            details: "printer Ruru_Copier is idle.  enabled since x\n\tForm mounted:\n\tDescription: Ruru Copier\nprinter Tony_s_Printer is idle.\n\tDescription: Tony's Printer\n")
        #expect(list.map(\.name) == ["Ruru_Copier", "Tony_s_Printer"])
        #expect(list[0].isDefault && !list[1].isDefault)
        #expect(list[0].description == "Ruru Copier")
        #expect(list[1].uri == "dnssd://x")
    }

    @Test func printerNameIsPartOfWhatsSigned() throws {
        var a = try FleetAction(id: "p", serial: "SERIAL1", kind: .removePrinter, module: nil, issued: Date(),
                                expires: Date(timeIntervalSinceNow: 60), printer: "Tui_Copier").signed(with: consoleKey)
        try a.verify(publicKey: console.publicKey, serial: "SERIAL1")
        a.printer = "Ruru_Copier"
        #expect(throws: FleetAction.Rejection.badSignature) { try a.verify(publicKey: console.publicKey, serial: "SERIAL1") }
    }

    func printerSetup() throws -> (Paths, FleetReporter, ScriptedShell) {
        let p = testPaths(tempDir())
        try FileManager.default.createDirectory(at: p.configCache.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cfg = AgentConfig(configVersion: 1, printers: PrintersConfig(ppd: "/x", queues: [.init(name: "Ruru_Copier", uri: "lpd://1/")]))
        try PropertyListEncoder().encode(cfg).write(to: p.configCache)
        let shell = ScriptedShell()
        return (p, FleetReporter(console: console, paths: p, shell: shell, system: FakeSystem()), shell)
    }

    @Test func removedSchoolCopierStaysRemovedUntilAdded() throws {
        let (p, reporter, shell) = try printerSetup()
        #expect(try reporter.removePrinter("Ruru_Copier") == "removed Ruru_Copier")
        #expect(shell.calls.contains("/usr/sbin/lpadmin -x Ruru_Copier"))
        #expect(FleetRequests.load(p).removed == ["Ruru_Copier"])
        #expect(try reporter.addPrinter("Ruru_Copier") == "added Ruru_Copier")
        #expect(FleetRequests.load(p).removed.isEmpty)
    }

    @Test func refusesBadPrinterRequests() throws {
        let (p, reporter, shell) = try printerSetup()
        #expect(throws: ModuleError.self) { try reporter.addPrinter("Not_A_School_Copier") }
        for bad in ["-x", "a b", "../etc", "a;rm", ""] {
            #expect(throws: ModuleError.self) { try reporter.removePrinter(bad) }
        }
        #expect(!shell.calls.contains { $0.hasPrefix("/usr/sbin/lpadmin") })
        _ = try reporter.removePrinter("Tony_s_Printer")   // not a school copier: removed, not remembered
        #expect(FleetRequests.load(p).removed.isEmpty)
    }

    @Test func moduleDoesNotReAddRemovedCopierAndMovesDefault() throws {
        let dir = tempDir()
        let p = testPaths(dir)
        try FileManager.default.createDirectory(at: p.configCache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FleetRequests(removedPrinters: ["Ruru_Copier"]).save(p)
        let ppd = dir.appendingPathComponent("apeos.ppd")
        try Data("*PPD-Adobe: \"4.3\"\n".utf8).write(to: ppd)
        let shell = ScriptedShell { cmd in
            if cmd.hasPrefix("/usr/bin/lpstat -v") { return CommandResult(exitCode: 1) }
            if cmd == "/usr/bin/lpstat -d" { return CommandResult(exitCode: 0, stdout: "no system default destination\n") }
            return CommandResult(exitCode: 0)
        }
        let config = AgentConfig(configVersion: 1, printers: PrintersConfig(ppd: ppd.path, queues: [
            .init(name: "Ruru_Copier", uri: "lpd://1/"), .init(name: "Tui_Copier", uri: "lpd://2/")], defaultQueue: "Ruru_Copier"))
        let runner = try makeRunner(dir, shell: shell, system: FakeSystem(files: [ppd.path]), modules: [PrinterQueuesModule(ppdDir: dir)])
        #expect(runner.run(config: config, options: RunOptions(scope: .device, subject: "device")).results["printer-queues"] == .changed)
        #expect(!shell.calls.contains { $0.hasPrefix("/usr/sbin/lpadmin -p Ruru_Copier") })
        #expect(shell.calls.contains { $0.hasPrefix("/usr/sbin/lpadmin -p Tui_Copier") })
        #expect(shell.calls.contains("/usr/bin/lpoptions -d Tui_Copier"))
    }
}
