import Foundation
import Testing
@testable import MacAgentCore

private let chrome = "/Applications/Google Chrome.app"
private let drive = "/Applications/Google Drive.app"
private let calendar = "/System/Applications/Calendar.app"
private let word = "/Applications/Microsoft Word.app"

private func dockPaths(_ prefs: FakePrefs) -> [String?] {
    (prefs.value("persistent-apps", domain: "com.apple.dock") as? [Any] ?? []).map(DockModule.path(of:))
}

private func session(_ user: String = "annabellesimpson", force: Bool = false) -> RunOptions {
    RunOptions(scope: .session, subject: user, force: force)
}

@Suite struct DockTests {
    let config = AgentConfig(configVersion: 1, dock: DockConfig(apps: [chrome, drive, calendar, word], showRecents: false))

    @Test func buildsWithInstalledAppsOnly() throws {
        let prefs = FakePrefs()
        let shell = FakeShell()
        let runner = try makeRunner(tempDir(), shell: shell, system: FakeSystem(files: [calendar]), prefs: prefs)
        let summary = runner.run(config: config, options: session())
        #expect(summary.results["dock"] == .changed)
        #expect(dockPaths(prefs) == [calendar])
        #expect((prefs.value("show-recents", domain: "com.apple.dock") as? Bool) == false)
        #expect(shell.calls.contains("/usr/bin/killall Dock"))
    }

    @Test func slotsLateAppsInOrderWithoutTouchingUserChanges() throws {
        let dir = tempDir()
        let prefs = FakePrefs()
        _ = try makeRunner(dir, shell: FakeShell(), system: FakeSystem(files: [calendar, word]), prefs: prefs)
            .run(config: config, options: session())
        #expect(dockPaths(prefs) == [calendar, word])

        // The user adds their own app at the end.
        var tiles = prefs.value("persistent-apps", domain: "com.apple.dock") as! [Any]
        tiles.append(DockModule.tile(for: "/Applications/Spotify.app"))
        prefs.set("persistent-apps", tiles, domain: "com.apple.dock")

        // Chrome and Drive finish installing.
        let later = try makeRunner(dir, shell: FakeShell(), system: FakeSystem(files: [chrome, drive, calendar, word]),
                                   prefs: prefs)
        let summary = later.run(config: config, options: session())
        #expect(summary.results["dock"] == .changed)
        #expect(dockPaths(prefs) == [chrome, drive, calendar, word, "/Applications/Spotify.app"])
    }

    @Test func removedAppStaysRemoved() throws {
        let dir = tempDir()
        let prefs = FakePrefs()
        let all = FakeSystem(files: [chrome, drive, calendar, word])
        _ = try makeRunner(dir, shell: FakeShell(), system: all, prefs: prefs).run(config: config, options: session())

        // The user removes Word from their Dock.
        let tiles = (prefs.value("persistent-apps", domain: "com.apple.dock") as! [Any]).filter { DockModule.path(of: $0) != word }
        prefs.set("persistent-apps", tiles, domain: "com.apple.dock")

        let summary = try makeRunner(dir, shell: FakeShell(), system: all, prefs: prefs).run(config: config, options: session())
        #expect(summary.results["dock"] == .ok)
        #expect(!dockPaths(prefs).contains(word))
    }

    @Test func configChangeRebuildsOnce() throws {
        let dir = tempDir()
        let prefs = FakePrefs()
        let system = FakeSystem(files: [chrome, drive, calendar, word])
        let runner = try makeRunner(dir, shell: FakeShell(), system: system, prefs: prefs)
        _ = runner.run(config: config, options: session())

        let newConfig = AgentConfig(configVersion: 2, dock: DockConfig(apps: [word, chrome]))
        #expect(runner.run(config: newConfig, options: session()).results["dock"] == .changed)
        #expect(dockPaths(prefs) == [word, chrome])
        #expect(runner.run(config: newConfig, options: session()).results["dock"] == .ok)
    }

    @Test func refusedWriteIsAFailureNotASuccess() throws {
        let prefs = FakePrefs()
        prefs.refuseSync = true
        let runner = try makeRunner(tempDir(), shell: FakeShell(), system: FakeSystem(files: [chrome]), prefs: prefs)
        #expect(runner.run(config: config, options: session()).results["dock"] == .fail)
        // Not recorded as built, so the next run tries again.
        prefs.refuseSync = false
        #expect(runner.run(config: config, options: session()).results["dock"] == .changed)
    }

    @Test func slotPositions() {
        let order = [chrome, drive, calendar, word]
        let tiles = [calendar].map(DockModule.tile)
        #expect(DockModule.slot(for: chrome, in: tiles, order: order) == 0)   // before the next listed app
        #expect(DockModule.slot(for: word, in: tiles, order: order) == 1)     // after the previous listed app
        #expect(DockModule.slot(for: word, in: [], order: order) == 0)
    }
}

@Suite struct PreferencesTests {
    let finder = PreferenceEntry(
        domain: "com.apple.finder",
        settings: [
            "ShowPathbar": .bool(true),
            "FXPreferredViewStyle": .string("Nlsv"),
            "DesktopViewSettings": .dict(["IconSize": .int(64)]),
        ],
        restart: "Finder")

    @Test func setsValuesMergesDictsAndRestarts() throws {
        let prefs = FakePrefs()
        prefs.set("DesktopViewSettings", ["GroupBy": "Kind"] as NSDictionary, domain: "com.apple.finder")
        let shell = FakeShell()
        let runner = try makeRunner(tempDir(), shell: shell, system: FakeSystem(), prefs: prefs)
        let summary = runner.run(config: AgentConfig(configVersion: 1, preferences: [finder]), options: session())
        #expect(summary.results["preferences"] == .changed)
        #expect((prefs.value("ShowPathbar", domain: "com.apple.finder") as? Bool) == true)
        let desktop = prefs.value("DesktopViewSettings", domain: "com.apple.finder") as? [String: Any]
        #expect(desktop?["GroupBy"] as? String == "Kind")     // kept
        #expect(desktop?["IconSize"] as? Int == 64)          // added
        #expect(shell.calls == ["/usr/bin/killall Finder"])
    }

    @Test func onceLeavesUserChangesAlone() throws {
        let prefs = FakePrefs()
        let shell = FakeShell()
        let runner = try makeRunner(tempDir(), shell: shell, system: FakeSystem(), prefs: prefs)
        let config = AgentConfig(configVersion: 1, preferences: [finder])
        _ = runner.run(config: config, options: session())

        prefs.set("ShowPathbar", false, domain: "com.apple.finder")
        #expect(runner.run(config: config, options: session()).results["preferences"] == .ok)
        #expect((prefs.value("ShowPathbar", domain: "com.apple.finder") as? Bool) == false)
        #expect(shell.calls.count == 1)   // Finder only restarted the first time
    }

    @Test func alwaysPutsItBackAsDrift() throws {
        var enforced = finder
        enforced.enforce = "always"
        let prefs = FakePrefs()
        let runner = try makeRunner(tempDir(), shell: FakeShell(), system: FakeSystem(), prefs: prefs)
        let config = AgentConfig(configVersion: 1, preferences: [enforced])
        _ = runner.run(config: config, options: session())

        prefs.set("ShowPathbar", false, domain: "com.apple.finder")
        #expect(runner.run(config: config, options: session()).results["preferences"] == .drift)
        #expect((prefs.value("ShowPathbar", domain: "com.apple.finder") as? Bool) == true)
        #expect(runner.run(config: config, options: session()).results["preferences"] == .ok)
    }

    @Test func plistValuesDecodeWithTheRightTypes() throws {
        let xml = Data("""
            <plist version="1.0"><dict>
              <key>ConfigVersion</key><integer>1</integer>
              <key>Preferences</key><array><dict>
                <key>Domain</key><string>com.apple.finder</string>
                <key>Settings</key><dict>
                  <key>B</key><true/><key>I</key><integer>64</integer><key>R</key><real>1.5</real>
                  <key>S</key><string>Nlsv</string>
                  <key>D</key><dict><key>Nested</key><false/></dict>
                </dict>
              </dict></array>
            </dict></plist>
            """.utf8)
        let config = try ConfigLoader.decode(data: xml, source: "test").get()
        let s = try #require(config.preferences?.first?.settings)
        #expect(s["B"] == .bool(true))
        #expect(s["I"] == .int(64))
        #expect(s["R"] == .real(1.5))
        #expect(s["S"] == .string("Nlsv"))
        #expect(s["D"] == .dict(["Nested": .bool(false)]))
    }

    @Test func rejectsDuplicateDomainsAndBadEnforce() {
        var bad = finder
        bad.enforce = "sometimes"
        let problems = AgentConfig(configVersion: 1, preferences: [finder, bad]).validate()
        #expect(problems.contains { $0.contains("more than once") })
        #expect(problems.contains { $0.contains("once or always") })
    }
}
