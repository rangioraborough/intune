import Foundation
import Testing
@testable import MacAgentCore

@Suite struct DeviceNameTests {
    let config = AgentConfig(configVersion: 1, excludedUsers: ["itadmin"], deviceName: DeviceNameConfig())

    @Test func modelCodesUseLongestPrefix() {
        #expect(DeviceNameModule.modelCode(for: "MacBook Air", overrides: [:]) == "MBA")
        #expect(DeviceNameModule.modelCode(for: "MacBook Pro", overrides: [:]) == "MBP")
        #expect(DeviceNameModule.modelCode(for: "MacBook", overrides: [:]) == "MB")
        #expect(DeviceNameModule.modelCode(for: "Mac mini", overrides: [:]) == "MacMini")
        #expect(DeviceNameModule.modelCode(for: "Mac Neo Thing", overrides: [:]) == "MacN")
        #expect(DeviceNameModule.modelCode(for: "MacBook Air", overrides: ["MacBook Air": "AIR"]) == "AIR")
    }

    @Test func formatsUsernamesLikeTheOldScript() {
        #expect(DeviceNameModule.formatUser("annabellesimpson") == "Annabellesimpson")
        #expect(DeviceNameModule.formatUser("anna.simpson") == "AnnaSimpson")
    }

    @Test func hostSafeStripsIllegalCharacters() {
        #expect(DeviceNameModule.hostSafe("MBA-Zoë O'Neil") == "MBA-Zo-O-Neil")
        #expect(DeviceNameModule.hostSafe(String(repeating: "a", count: 80)).count == 63)
    }

    @Test func renamesFreshMacAfterConsoleUser() throws {
        let scutil = FakeScutil(["ComputerName": "Annabelle’s MacBook Air", "LocalHostName": "Annabelles-MacBook-Air"])
        let runner = try makeRunner(tempDir(), shell: scutil, system: FakeSystem(user: "annabellesimpson"))
        let summary = runner.run(config: config, options: RunOptions(scope: .device, subject: "device"))
        #expect(summary.results["device-name"] == .changed)
        #expect(scutil.names["ComputerName"] == "MBA-Annabellesimpson")
        #expect(scutil.names["LocalHostName"] == "MBA-Annabellesimpson")
        #expect(scutil.names["HostName"] == "MBA-Annabellesimpson")
    }

    @Test func usesTheAccountsFullName() throws {
        let scutil = FakeScutil([:])
        var system = FakeSystem(user: "kellytaylor", hw: HardwareInfo(modelName: "Mac mini", serial: "X"))
        system.fullNames = ["kellytaylor": "Kelly Taylor"]
        let runner = try makeRunner(tempDir(), shell: scutil, system: system)
        _ = runner.run(config: config, options: RunOptions(scope: .device, subject: "device"))
        #expect(scutil.names["ComputerName"] == "MacMini-KellyTaylor")
        #expect(scutil.names["LocalHostName"] == "MacMini-KellyTaylor")
    }

    @Test func locksToFirstUserOnSharedMac() throws {
        let dir = tempDir()
        let scutil = FakeScutil([:])
        let first = try makeRunner(dir, shell: scutil, system: FakeSystem(user: "annabellesimpson"))
        _ = first.run(config: config, options: RunOptions(scope: .device, subject: "device"))

        let second = try makeRunner(dir, shell: scutil, system: FakeSystem(user: "someone.else"))
        let summary = second.run(config: config, options: RunOptions(scope: .device, subject: "device"))
        #expect(summary.results["device-name"] == .ok)
        #expect(scutil.names["ComputerName"] == "MBA-Annabellesimpson")
    }

    @Test func waitsAtLoginWindowAndForExcludedUsers() throws {
        let scutil = FakeScutil([:])
        let atLogin = try makeRunner(tempDir(), shell: scutil, system: FakeSystem(user: nil))
        #expect(atLogin.run(config: config, options: RunOptions(scope: .device, subject: "device"))
                    .results["device-name"] == .waiting)
        let asAdmin = try makeRunner(tempDir(), shell: scutil, system: FakeSystem(user: "itadmin"))
        #expect(asAdmin.run(config: config, options: RunOptions(scope: .device, subject: "device"))
                    .results["device-name"] == .waiting)
        #expect(scutil.sets.isEmpty)
    }

    @Test func manualRenameIsDriftAndGetsPutBack() throws {
        let dir = tempDir()
        let scutil = FakeScutil([:])
        let runner = try makeRunner(dir, shell: scutil, system: FakeSystem(user: "annabellesimpson"))
        _ = runner.run(config: config, options: RunOptions(scope: .device, subject: "device"))

        scutil.names["ComputerName"] = "Annabelle's Laptop"
        let summary = runner.run(config: config, options: RunOptions(scope: .device, subject: "device"))
        #expect(summary.results["device-name"] == .drift)
        #expect(scutil.names["ComputerName"] == "MBA-Annabellesimpson")
    }

    @Test func templateChangeIsChangedNotDrift() throws {
        let dir = tempDir()
        let scutil = FakeScutil([:])
        let runner = try makeRunner(dir, shell: scutil, system: FakeSystem(user: "annabellesimpson"))
        _ = runner.run(config: config, options: RunOptions(scope: .device, subject: "device"))

        var serialConfig = config
        serialConfig.deviceName = DeviceNameConfig(template: "{model}-{serial}")
        let summary = runner.run(config: serialConfig, options: RunOptions(scope: .device, subject: "device"))
        #expect(summary.results["device-name"] == .changed)
        #expect(scutil.names["ComputerName"] == "MBA-C02TEST123")
    }

    @Test func dryRunChangesNothingAndSavesNoState() throws {
        let dir = tempDir()
        let scutil = FakeScutil([:])
        let runner = try makeRunner(dir, shell: scutil, system: FakeSystem(user: "annabellesimpson"))
        let summary = runner.run(config: config, options: RunOptions(scope: .device, subject: "device", dryRun: true))
        #expect(summary.results["device-name"] == .changed)
        #expect(scutil.sets.isEmpty)
        #expect(runner.state.all().isEmpty)
    }

    @Test func disabledModuleDoesNotRun() throws {
        let scutil = FakeScutil([:])
        let runner = try makeRunner(tempDir(), shell: scutil, system: FakeSystem(user: "annabellesimpson"))
        let off = AgentConfig(configVersion: 1, deviceName: DeviceNameConfig(enabled: false))
        #expect(runner.run(config: off, options: RunOptions(scope: .device, subject: "device")).results["device-name"] == nil)
        #expect(scutil.sets.isEmpty)
    }
}

/// `enforce: once` behaviour, tested with a stub module since no real `once` module exists yet.
@Suite struct EnforceOnceTests {
    final class Counter: @unchecked Sendable { var runs = 0 }

    struct OnceModule: Module {
        let id = "stub-once"
        let scope = Scope.session
        let enforce = Enforce.once
        let counter: Counter
        func configHash(_ config: AgentConfig) -> String? { ConfigHash.of(config.configVersion) }
        func run(_ ctx: ModuleContext, data: inout [String: String]) throws -> Outcome {
            counter.runs += 1
            return .changed("applied")
        }
    }

    @Test func runsOncePerConfigThenLeavesUserAlone() throws {
        let counter = Counter()
        let runner = try makeRunner(tempDir(), shell: FakeShell(), system: FakeSystem(user: "a"),
                                    modules: [OnceModule(counter: counter)])
        let opts = RunOptions(scope: .session, subject: "a")
        _ = runner.run(config: AgentConfig(configVersion: 1), options: opts)
        _ = runner.run(config: AgentConfig(configVersion: 1), options: opts)
        #expect(counter.runs == 1)

        _ = runner.run(config: AgentConfig(configVersion: 2), options: opts)   // config changed → once more
        #expect(counter.runs == 2)

        var forced = opts
        forced.force = true
        _ = runner.run(config: AgentConfig(configVersion: 2), options: forced)
        #expect(counter.runs == 3)
    }

    @Test func eachUserGetsTheirOwnRun() throws {
        let counter = Counter()
        let runner = try makeRunner(tempDir(), shell: FakeShell(), system: FakeSystem(user: "a"),
                                    modules: [OnceModule(counter: counter)])
        _ = runner.run(config: AgentConfig(configVersion: 1), options: RunOptions(scope: .session, subject: "a"))
        _ = runner.run(config: AgentConfig(configVersion: 1), options: RunOptions(scope: .session, subject: "b"))
        #expect(counter.runs == 2)
    }
}
