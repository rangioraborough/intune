import Foundation
import Testing
@testable import MacAgentCore

@Suite struct LegacyCleanupTests {
    let fm = FileManager.default
    let logs = "/Library/Logs/Microsoft/IntuneScripts"

    /// A Mac as the old scripts left it: Dock + Finder + InstallApps folders, worker plist, /Library/RBS.
    func oldMac(_ p: Paths) {
        touch(p, "\(logs)/ConfigureDock/ConfigureDock.log")
        touch(p, "\(logs)/ConfigureDock/ConfigureDock.v3.done")
        touch(p, "\(logs)/ConfigureFinder/ConfigureFinder.log")
        touch(p, "\(logs)/InstallApps/InstallApps.log")
        touch(p, "/Library/LaunchDaemons/nz.school.rangiora.installapps-worker.plist")
        touch(p, "/Library/RBS/Wallpaper/RBS-Background.jpg")
    }

    func run(_ dir: URL, applied: Set<String>) throws -> (RunSummary, FakeShell) {
        let shell = FakeShell()
        var runner = try makeRunner(dir, shell: shell, system: FakeSystem(), modules: [LegacyCleanupModule()])
        // Stand in for the dock/preferences/etc state that would come from real runs.
        runner.appliedOverride = { applied.contains($0) }
        return (runner.run(config: AgentConfig(configVersion: 1), options: RunOptions(scope: .device, subject: "device")), shell)
    }

    @Test func onlyCleansScriptsWhoseReplacementHasApplied() throws {
        let dir = tempDir()
        let p = testPaths(dir)
        oldMac(p)
        let (summary, shell) = try run(dir, applied: ["dock"])
        #expect(summary.results["legacy-cleanup"] == .changed)
        #expect(!fm.fileExists(atPath: p.resolve("\(logs)/ConfigureDock").path))
        #expect(fm.fileExists(atPath: p.resolve("\(logs)/ConfigureFinder").path))      // preferences not applied yet
        #expect(fm.fileExists(atPath: p.resolve("\(logs)/InstallApps").path))          // apps module doesn't exist yet
        #expect(fm.fileExists(atPath: p.resolve("/Library/RBS/Wallpaper").path))       // wallpaper not replaced yet
        #expect(shell.calls.isEmpty)

        let archived = try fm.contentsOfDirectory(atPath: p.legacyArchive.path)
        #expect(archived.count == 1 && archived[0].hasPrefix("ConfigureDock-"))
        #expect(fm.fileExists(atPath: p.legacyArchive.appendingPathComponent(archived[0]).appendingPathComponent("ConfigureDock.log").path))
    }

    @Test func removesWorkerDaemonAndEmptyRBSWhenReplaced() throws {
        let dir = tempDir()
        let p = testPaths(dir)
        oldMac(p)
        let (_, shell) = try run(dir, applied: ["apps", "wallpaper"])
        #expect(shell.calls.contains("/bin/launchctl bootout system/nz.school.rangiora.installapps-worker"))
        #expect(!fm.fileExists(atPath: p.resolve("/Library/LaunchDaemons/nz.school.rangiora.installapps-worker.plist").path))
        #expect(!fm.fileExists(atPath: p.resolve("/Library/RBS").path))   // empty after Wallpaper went
    }

    @Test func reportsOldScriptRunningAgainAsDrift() throws {
        let dir = tempDir()
        let p = testPaths(dir)
        oldMac(p)
        _ = try run(dir, applied: ["dock"])
        #expect(try run(dir, applied: ["dock"]).0.results["legacy-cleanup"] == .ok)

        touch(p, "\(logs)/ConfigureDock/ConfigureDock.log")   // Intune ran the old script again
        #expect(try run(dir, applied: ["dock"]).0.results["legacy-cleanup"] == .drift)
    }

    @Test func dryRunTouchesNothing() throws {
        let dir = tempDir()
        let p = testPaths(dir)
        oldMac(p)
        let shell = FakeShell()
        var runner = try makeRunner(dir, shell: shell, system: FakeSystem(), modules: [LegacyCleanupModule()])
        runner.appliedOverride = { _ in true }
        let summary = runner.run(config: AgentConfig(configVersion: 1),
                                 options: RunOptions(scope: .device, subject: "device", dryRun: true))
        #expect(summary.results["legacy-cleanup"] == .changed)
        #expect(fm.fileExists(atPath: p.resolve("\(logs)/ConfigureDock").path))
        #expect(shell.calls.isEmpty)
    }

    @Test func seesSessionModulesAppliedForAnyUser() throws {
        let dir = tempDir()
        let p = testPaths(dir)
        let home = p.usersDir.appendingPathComponent("annabellesimpson")
        let store = try StateStore(url: Paths.session(home: home).stateDB)
        try store.put(ModuleState(module: "dock", subject: "annabellesimpson", configHash: "x", lastRun: Date(),
                                  result: .changed, duration: 0, detail: "", agentVersion: "t", data: [:]))
        let runner = try makeRunner(dir, shell: FakeShell(), system: FakeSystem(), modules: [])
        #expect(runner.appliedAnywhere("dock"))
        #expect(!runner.appliedAnywhere("preferences"))
    }
}
