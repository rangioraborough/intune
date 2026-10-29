import Foundation
import Testing
@testable import MacAgentCore

private func device(force: Bool = false) -> RunOptions { RunOptions(scope: .device, subject: "device", force: force) }

@Suite struct PasswordHashTests {
    @Test func roundTripsAndVerifies() throws {
        let h = PasswordHash.make(password: "correct horse battery staple", iterations: 20_000)
        let parsed = try #require(PasswordHash(string: h.string))
        #expect(parsed == h)
        #expect(h.matches(password: "correct horse battery staple"))
        #expect(!h.matches(password: "wrong"))
        #expect(PasswordHash(shadowHashData: h.shadowHashData) == h)
    }

    @Test func rejectsJunk() {
        #expect(PasswordHash(string: "") == nil)
        #expect(PasswordHash(string: "pbkdf2-sha512$5$AAAA$BBBB") == nil)
    }
}

@Suite struct AdminAccountTests {
    let hash = PasswordHash.make(password: "a long test passphrase", iterations: 20_000)
    var config: AgentConfig {
        AgentConfig(configVersion: 1, adminAccount: AdminAccountConfig(username: "itadmin", fullName: "IT Admin",
                                                                       passwordHash: hash.string))
    }

    @Test func createsHidesAndSetsPassword() throws {
        let dir = FakeDirectory()
        let runner = try makeRunner(tempDir(), shell: FakeShell(), system: FakeSystem(), modules: [AdminAccountModule(directory: dir)])
        #expect(runner.run(config: config, options: device()).results["admin-account"] == .changed)
        let a = try #require(dir.accounts["itadmin"])
        #expect(a.hidden && a.admin)
        #expect(PasswordHash(shadowHashData: a.shadow!) == hash)
        #expect(runner.run(config: config, options: device()).results["admin-account"] == .ok)
    }

    @Test func resetsTodaysBlankPasswordAccount() throws {
        let dir = FakeDirectory()
        dir.accounts["itadmin"] = .init(shadow: PasswordHash.make(password: "", iterations: 20_000).shadowHashData,
                                        hidden: true, admin: true)
        let runner = try makeRunner(tempDir(), shell: FakeShell(), system: FakeSystem(), modules: [AdminAccountModule(directory: dir)])
        #expect(runner.run(config: config, options: device()).results["admin-account"] == .changed)
        #expect(dir.created.isEmpty)
        #expect(PasswordHash(shadowHashData: dir.accounts["itadmin"]!.shadow!)!.matches(password: "a long test passphrase"))
    }

    @Test func refusesToTouchSecureTokenAccount() throws {
        let dir = FakeDirectory()
        dir.accounts["itadmin"] = .init(shadow: nil, hidden: true, admin: true, token: true)
        let runner = try makeRunner(tempDir(), shell: FakeShell(), system: FakeSystem(), modules: [AdminAccountModule(directory: dir)])
        #expect(runner.run(config: config, options: device()).results["admin-account"] == .fail)
        #expect(dir.accounts["itadmin"]!.shadow == nil)
    }

    @Test func removesOldAdminButNeverTheLoggedInUser() throws {
        let dir = FakeDirectory()
        dir.accounts["itadmin"] = .init(shadow: nil, hidden: true, admin: true)
        var cfg = config
        cfg.adminAccount?.username = "admin"
        cfg.adminAccount?.removeAccounts = ["itadmin"]
        let loggedIn = try makeRunner(tempDir(), shell: FakeShell(), system: FakeSystem(user: "itadmin"),
                                      modules: [AdminAccountModule(directory: dir)])
        #expect(loggedIn.run(config: cfg, options: device()).results["admin-account"] == .fail)
        #expect(dir.accounts["itadmin"] != nil)

        let runner = try makeRunner(tempDir(), shell: FakeShell(), system: FakeSystem(user: "teacher"),
                                    modules: [AdminAccountModule(directory: dir)])
        #expect(runner.run(config: cfg, options: device()).results["admin-account"] == .changed)
        #expect(dir.accounts["itadmin"] == nil)
        #expect(dir.accounts["admin"] != nil)
        #expect(AdminAccountConfig(username: "admin", passwordHash: hash.string, removeAccounts: ["admin"]).validate().count == 1)
    }

    @Test func unhidesWhenConfigSaysVisible() throws {
        let dir = FakeDirectory()
        dir.accounts["itadmin"] = .init(shadow: hash.shadowHashData, hidden: true, admin: true)
        var cfg = config
        cfg.adminAccount?.hidden = false
        let runner = try makeRunner(tempDir(), shell: FakeShell(), system: FakeSystem(), modules: [AdminAccountModule(directory: dir)])
        #expect(runner.run(config: cfg, options: device()).results["admin-account"] == .changed)
        #expect(dir.accounts["itadmin"]?.hidden == false)
    }

    @Test func adminAccountIsAlwaysExcluded() {
        #expect(config.allExcludedUsers.contains("itadmin"))
    }
}

@Suite struct AvatarTests {
    @Test func setsOncePerUserWithOverrides() throws {
        let tmp = tempDir()
        let p = testPaths(tmp)
        let teacher = p.siteResources.appendingPathComponent("avatars/teacher.png").path
        let admin = p.siteResources.appendingPathComponent("avatars/admin.png").path
        let dir = FakeDirectory()
        dir.accounts = ["annabellesimpson": .init(shadow: nil), "itadmin": .init(shadow: nil)]
        let config = AgentConfig(configVersion: 1, excludedUsers: ["itadmin"],
                                 avatar: AvatarConfig(defaultImage: "avatars/teacher.png", users: ["itadmin": "avatars/admin.png"]))
        let runner = try makeRunner(tmp, shell: FakeShell(), system: FakeSystem(files: [teacher, admin]),
                                    modules: [AvatarModule(directory: dir)])
        #expect(runner.run(config: config, options: device()).results["avatar"] == .changed)
        #expect(dir.accounts["annabellesimpson"]?.picture == teacher)
        #expect(dir.accounts["itadmin"]?.picture == admin)   // override applies even though excluded

        dir.accounts["annabellesimpson"]?.picture = "/Users/annabellesimpson/me.png"   // she changes it
        dir.accounts["newteacher"] = .init(shadow: nil)
        #expect(runner.run(config: config, options: device()).results["avatar"] == .changed)
        #expect(dir.accounts["annabellesimpson"]?.picture == "/Users/annabellesimpson/me.png")   // kept
        #expect(dir.accounts["newteacher"]?.picture == teacher)
    }

    @Test func waitsForSiteResources() throws {
        let dir = FakeDirectory()
        dir.accounts = ["a": .init(shadow: nil)]
        let runner = try makeRunner(tempDir(), shell: FakeShell(), system: FakeSystem(), modules: [AvatarModule(directory: dir)])
        let config = AgentConfig(configVersion: 1, avatar: AvatarConfig(defaultImage: "avatars/teacher.png"))
        #expect(runner.run(config: config, options: device()).results["avatar"] == .waiting)
    }
}

@Suite struct MAUTests {
    @Test func turnsOffAndReportsDriftWhenOfficePutsItBack() throws {
        let tmp = tempDir()
        let p = testPaths(tmp)
        touch(p, MAUModule.launchAgent)
        var prefs: [String: String] = [:]
        let shell = ScriptedShell { cmd in
            let parts = cmd.split(separator: " ").map(String.init)
            if parts.first == "/usr/bin/defaults", parts[1] == "read" { return CommandResult(exitCode: 0, stdout: prefs[parts[3]] ?? "") }
            if parts.first == "/usr/bin/defaults", parts[1] == "write" { prefs[parts[3]] = "0" }
            return CommandResult(exitCode: 0)
        }
        let config = AgentConfig(configVersion: 1, microsoftAutoUpdate: MAUConfig(disable: true))
        let runner = try makeRunner(tmp, shell: shell, system: FakeSystem(), modules: [MAUModule()])
        #expect(runner.run(config: config, options: device()).results["mau-disable"] == .changed)
        #expect(!FileManager.default.fileExists(atPath: p.resolve(MAUModule.launchAgent).path))
        #expect(runner.run(config: config, options: device()).results["mau-disable"] == .ok)

        touch(p, MAUModule.launchAgent)   // an Office update restores it
        #expect(runner.run(config: config, options: device()).results["mau-disable"] == .drift)
    }
}

@Suite struct AppsTests {
    let chrome = "/Applications/Google Chrome.app"
    let vlc = "/Applications/VLC.app"

    @Test func installsOnlyWhatIsMissing() throws {
        let system = MutableSystem(files: [vlc])
        let shell = ScriptedShell { cmd in
            if cmd.contains("Installomator.sh googlechrome") { system.files.insert("/Applications/Google Chrome.app") }
            if cmd == "/usr/sbin/sysctl -n hw.optional.arm64" { return CommandResult(exitCode: 0, stdout: "0") }
            return CommandResult(exitCode: 0)
        }
        let config = AgentConfig(configVersion: 1, apps: AppsConfig(install: [.init(label: "googlechrome", path: chrome),
                                                                              .init(label: "vlc", path: vlc)]))
        let runner = try makeRunner(tempDir(), shell: shell, system: system, modules: [AppsModule()])
        let summary = runner.run(config: config, options: device())
        #expect(summary.results["apps"] == .changed)
        #expect(shell.calls.contains { $0.contains("Installomator.sh googlechrome DEBUG=0 NOTIFY=silent") })
        #expect(!shell.calls.contains { $0.contains("Installomator.sh vlc") })
        #expect(runner.run(config: config, options: device()).results["apps"] == .ok)
    }

    @Test func failedInstallIsAFailure() throws {
        let shell = ScriptedShell { cmd in
            cmd.contains("Installomator") ? CommandResult(exitCode: 1, stdout: "ERROR: download failed") : CommandResult(exitCode: 0)
        }
        let config = AgentConfig(configVersion: 1, apps: AppsConfig(install: [.init(label: "googlechrome", path: chrome)]))
        let runner = try makeRunner(tempDir(), shell: shell, system: MutableSystem(), modules: [AppsModule()])
        #expect(runner.run(config: config, options: device()).results["apps"] == .fail)
    }

    @Test func rosettaGatedPackageWaitsThenInstalls() throws {
        let tmp = tempDir()
        let p = testPaths(tmp)
        let pkg = p.siteResources.appendingPathComponent("drivers/apeos.pkg").path
        let system = MutableSystem(files: [pkg])
        var rosettaWorks = false
        let shell = ScriptedShell { cmd in
            if cmd == "/usr/sbin/sysctl -n hw.optional.arm64" { return CommandResult(exitCode: 0, stdout: "1") }
            if cmd.hasPrefix("/usr/sbin/pkgutil") { return CommandResult(exitCode: 1) }
            if cmd.hasPrefix("/usr/sbin/softwareupdate"), rosettaWorks { system.files.insert(AppsModule.rosettaRuntime) }
            return CommandResult(exitCode: 0)
        }
        let config = AgentConfig(configVersion: 1, apps: AppsConfig(rosetta: true, packages: [
            .init(file: "drivers/apeos.pkg", receipt: "com.fujifilm.x", needsRosetta: true)]))
        let runner = try makeRunner(tmp, shell: shell, system: system, modules: [AppsModule()])
        #expect(runner.run(config: config, options: device()).results["apps"] == .fail)   // Rosetta didn't land
        #expect(!shell.calls.contains { $0.hasPrefix("/usr/sbin/installer") })
        rosettaWorks = true
        #expect(runner.run(config: config, options: device()).results["apps"] == .changed)
        #expect(shell.calls.contains { $0.hasPrefix("/usr/sbin/installer -pkg \(pkg)") })
    }
}

@Suite struct PinnedPackageTests {
    let word = "/Applications/Microsoft Word.app"
    let sha = String(repeating: "a", count: 64)

    @Test func replacesWrongVersionAndChecksHashAndSigner() throws {
        let system = MutableSystem()
        system.versions[word] = "16.114.2"
        let shell = ScriptedShell { cmd in
            if cmd.hasPrefix("/usr/bin/openssl dgst") { return CommandResult(exitCode: 0, stdout: "\(String(repeating: "a", count: 64)) *file\n") }
            if cmd.hasPrefix("/usr/sbin/pkgutil --check-signature") { return CommandResult(exitCode: 0, stdout: "1. Developer ID Installer: Microsoft Corporation (UBF8T346G9)") }
            if cmd.hasPrefix("/usr/sbin/installer") { system.versions["/Applications/Microsoft Word.app"] = "16.113.4" }
            return CommandResult(exitCode: 0)
        }
        let config = AgentConfig(configVersion: 1, apps: AppsConfig(packages: [
            .init(url: "https://cdn.example/office.pkg", sha256: sha, teamID: "UBF8T346G9", app: word, version: "16.113.4")]))
        let runner = try makeRunner(tempDir(), shell: shell, system: system, modules: [AppsModule()])
        #expect(runner.run(config: config, options: RunOptions(scope: .device, subject: "device")).results["apps"] == .changed)
        #expect(system.versions[word] == "16.113.4")
        #expect(runner.run(config: config, options: RunOptions(scope: .device, subject: "device")).results["apps"] == .ok)
    }

    @Test func waitsWhileOfficeIsOpen() throws {
        let tmp = tempDir()
        let system = MutableSystem(files: [word])
        system.versions[word] = "16.114.2"
        let shell = ScriptedShell { cmd in
            cmd == "/usr/bin/pgrep -x Microsoft Word" ? CommandResult(exitCode: 0) : CommandResult(exitCode: 1)
        }
        let config = AgentConfig(configVersion: 1, apps: AppsConfig(packages: [
            .init(url: "https://cdn.example/office.pkg", sha256: sha, app: word, version: "16.113.4", replaceApps: [word])]))
        let runner = try makeRunner(tmp, shell: shell, system: system, modules: [AppsModule()])
        #expect(runner.run(config: config, options: RunOptions(scope: .device, subject: "device")).results["apps"] == .waiting)
        #expect(!shell.calls.contains { $0.hasPrefix("/usr/bin/curl") })
    }

    @Test func waitsWhileAnotherInstallerIsWritingTheApps() throws {
        let system = MutableSystem(files: [word])
        system.versions[word] = "16.114.2"
        system.modifiedDates[word] = Date(timeIntervalSinceNow: -60)   // Intune installed it a minute ago
        let shell = ScriptedShell { _ in CommandResult(exitCode: 1) }   // nothing open
        let config = AgentConfig(configVersion: 1, apps: AppsConfig(packages: [
            .init(url: "https://cdn.example/office.pkg", sha256: sha, app: word, version: "16.113.4", replaceApps: [word])]))
        let runner = try makeRunner(tempDir(), shell: shell, system: system, modules: [AppsModule()])
        #expect(runner.run(config: config, options: RunOptions(scope: .device, subject: "device")).results["apps"] == .waiting)
        #expect(!shell.calls.contains { $0.hasPrefix("/usr/bin/curl") })
    }

    @Test func refusesBadDownload() throws {
        let system = MutableSystem()
        let shell = ScriptedShell { cmd in
            if cmd.hasPrefix("/usr/bin/openssl dgst") { return CommandResult(exitCode: 0, stdout: "deadbeef *file") }
            return CommandResult(exitCode: 0)
        }
        let config = AgentConfig(configVersion: 1, apps: AppsConfig(packages: [
            .init(url: "https://cdn.example/office.pkg", sha256: sha, app: word, version: "16.113.4")]))
        let runner = try makeRunner(tempDir(), shell: shell, system: system, modules: [AppsModule()])
        #expect(runner.run(config: config, options: RunOptions(scope: .device, subject: "device")).results["apps"] == .fail)
        #expect(!shell.calls.contains { $0.hasPrefix("/usr/sbin/installer") })
    }
}

@Suite struct RemoveAppsTests {
    @Test func removesUnwantedAppsEveryTime() throws {
        let tmp = tempDir()
        let p = testPaths(tmp)
        touch(p, "/Applications/OneDrive.app/Contents/Info.plist")
        let shell = FakeShell()
        let runner = try makeRunner(tmp, shell: shell, system: MutableSystem(files: ["/Applications/OneDrive.app"]), modules: [AppsModule()])
        let config = AgentConfig(configVersion: 1, apps: AppsConfig(remove: ["/Applications/OneDrive.app"]))
        #expect(runner.run(config: config, options: RunOptions(scope: .device, subject: "device")).results["apps"] == .changed)
        #expect(shell.calls.contains { $0.hasPrefix("/usr/bin/pkill -f /Applications/OneDrive.app/Contents/MacOS/") })
        #expect(!FileManager.default.fileExists(atPath: p.resolve("/Applications/OneDrive.app").path))
        #expect(AppsConfig(remove: ["/System/Applications/Mail.app"]).validate().count == 1)
    }
}

@Suite struct WebAppsTests {
    @Test func buildsAndOnlyRebuildsOnChange() throws {
        let tmp = tempDir()
        let p = testPaths(tmp)
        touch(p, "/dummy")
        let shell = FakeShell()
        let web = WebAppConfig(name: "Classview", url: "https://rangiora.classview.co.nz", browser: "Google Chrome")
        let runner = try makeRunner(tmp, shell: shell, system: FakeSystem(), modules: [WebAppsModule()])
        #expect(runner.run(config: AgentConfig(configVersion: 1, webApps: [web]), options: device()).results["web-apps"] == .changed)
        let launcher = try String(contentsOf: p.resolve("/Applications/Classview.app/Contents/MacOS/launch"), encoding: .utf8)
        #expect(launcher.contains("/usr/bin/open -a 'Google Chrome' 'https://rangiora.classview.co.nz'"))
        #expect(runner.run(config: AgentConfig(configVersion: 1, webApps: [web]), options: device()).results["web-apps"] == .ok)

        var moved = web
        moved.url = "https://new.classview.co.nz"
        #expect(runner.run(config: AgentConfig(configVersion: 1, webApps: [moved]), options: device()).results["web-apps"] == .changed)
        #expect(shell.calls.contains("/usr/bin/killall Dock"))
    }
}

@Suite struct PrinterQueueTests {
    @Test func addsOnlyMissingOrWrongQueues() throws {
        let tmp = tempDir()
        let ppd = tmp.appendingPathComponent("apeos.ppd")
        try Data("*PPD-Adobe: \"4.3\"\n".utf8).write(to: ppd)
        let shell = ScriptedShell { cmd in
            if cmd == "/usr/bin/lpstat -v Ruru_Copier" { return CommandResult(exitCode: 0, stdout: "device for Ruru_Copier: lpd://10.69.192.23\n") }
            if cmd.hasPrefix("/usr/bin/lpstat -v") { return CommandResult(exitCode: 1) }
            if cmd == "/usr/bin/lpstat -d" { return CommandResult(exitCode: 0, stdout: "no system default destination\n") }
            return CommandResult(exitCode: 0)
        }
        let config = AgentConfig(configVersion: 1, printers: PrintersConfig(ppd: ppd.path, queues: [
            .init(name: "Ruru_Copier", uri: "lpd://10.69.192.23/", description: "Ruru Copier"),
            .init(name: "Tui_Copier", uri: "lpd://10.69.192.24/", description: "Tui Copier")], defaultQueue: "Ruru_Copier"))
        let runner = try makeRunner(tmp, shell: shell, system: FakeSystem(files: [ppd.path]), modules: [PrinterQueuesModule()])
        #expect(runner.run(config: config, options: device()).results["printer-queues"] == .changed)
        #expect(shell.calls.contains { $0.hasPrefix("/usr/sbin/lpadmin -p Tui_Copier -E -v lpd://10.69.192.24/") })
        #expect(!shell.calls.contains { $0.hasPrefix("/usr/sbin/lpadmin -p Ruru_Copier") })   // trailing slash difference ignored
        #expect(shell.calls.contains("/usr/bin/lpoptions -d Ruru_Copier"))
    }

    @Test func setsDefaultsInTheQueuesPPD() throws {
        // printers.conf already says one-sided (lpoptions shows *None), but the queue's PPD,
        // which the print dialog reads, still says two-sided: only the PPD is fixed.
        let tmp = tempDir()
        let driver = tmp.appendingPathComponent("apeos.ppd")
        try Data("*PPD-Adobe: \"4.3\"\n".utf8).write(to: driver)
        let ppdDir = tmp.appendingPathComponent("cups-ppd")
        try FileManager.default.createDirectory(at: ppdDir, withIntermediateDirectories: true)
        let queuePPD = ppdDir.appendingPathComponent("Ruru_Copier.ppd")
        try Data("*PPD-Adobe: \"4.3\"\r\n*DefaultDuplex: DuplexNoTumble\r\n*Duplex None: \"\"\r\n".utf8).write(to: queuePPD)
        let shell = ScriptedShell { cmd in
            if cmd.hasPrefix("/usr/bin/lpstat -v") { return CommandResult(exitCode: 0, stdout: "device for Ruru_Copier: lpd://10.69.192.23\n") }
            if cmd.hasPrefix("/usr/bin/lpoptions -p") { return CommandResult(exitCode: 0, stdout: "Duplex/2-Sided Printing: DuplexNoTumble *None DuplexTumble\n") }
            if cmd == "/usr/bin/lpstat -d" { return CommandResult(exitCode: 0, stdout: "system default destination: Ruru_Copier\n") }
            return CommandResult(exitCode: 0)
        }
        let config = AgentConfig(configVersion: 1, printers: PrintersConfig(ppd: driver.path, queues: [
            .init(name: "Ruru_Copier", uri: "lpd://10.69.192.23/")], options: ["Duplex": "None"]))
        let runner = try makeRunner(tmp, shell: shell, system: FakeSystem(files: [driver.path]),
                                    modules: [PrinterQueuesModule(ppdDir: ppdDir)])
        #expect(runner.run(config: config, options: device()).results["printer-queues"] == .changed)
        let text = try String(contentsOf: queuePPD, encoding: .isoLatin1)
        #expect(text.contains("*DefaultDuplex: None\r\n"))
        #expect(text.contains("*Duplex None: \"\""))
        #expect(!shell.calls.contains { $0.hasPrefix("/usr/sbin/lpadmin") })
        #expect(runner.run(config: config, options: device()).results["printer-queues"] == .ok)
    }

    @Test func waitsForDriver() throws {
        let config = AgentConfig(configVersion: 1, printers: PrintersConfig(ppd: "/nope.ppd", queues: [.init(name: "A", uri: "lpd://1.2.3.4/")]))
        let runner = try makeRunner(tempDir(), shell: FakeShell(), system: FakeSystem(), modules: [PrinterQueuesModule()])
        #expect(runner.run(config: config, options: device()).results["printer-queues"] == .waiting)
    }
}

@Suite struct LoginItemsTests {
    @Test func removesListedItemsAndReportsDrift() throws {
        let tmp = tempDir()
        let p = testPaths(tmp)
        touch(p, "/Library/LaunchDaemons/com.microsoft.OneDriveUpdaterDaemon.plist")
        touch(p, "/Library/LaunchAgents/com.microsoft.SyncReporter.plist")
        touch(p, "/Library/LaunchDaemons/com.microsoft.intuneMDMAgent.daemon.plist")
        let shell = FakeShell()
        let config = AgentConfig(configVersion: 1, loginItems: LoginItemsConfig(disable: [
            "com.microsoft.OneDriveUpdaterDaemon", "com.microsoft.SyncReporter"]))
        let runner = try makeRunner(tmp, shell: shell, system: FakeSystem(), modules: [LoginItemsModule()])
        #expect(runner.run(config: config, options: RunOptions(scope: .device, subject: "device")).results["login-items"] == .changed)
        #expect(!FileManager.default.fileExists(atPath: p.resolve("/Library/LaunchDaemons/com.microsoft.OneDriveUpdaterDaemon.plist").path))
        #expect(!FileManager.default.fileExists(atPath: p.resolve("/Library/LaunchAgents/com.microsoft.SyncReporter.plist").path))
        #expect(FileManager.default.fileExists(atPath: p.resolve("/Library/LaunchDaemons/com.microsoft.intuneMDMAgent.daemon.plist").path))
        #expect(shell.calls.contains("/bin/launchctl disable system/com.microsoft.OneDriveUpdaterDaemon"))

        touch(p, "/Library/LaunchDaemons/com.microsoft.OneDriveUpdaterDaemon.plist")   // a OneDrive update puts it back
        #expect(runner.run(config: config, options: RunOptions(scope: .device, subject: "device")).results["login-items"] == .drift)
    }

    @Test func protectedItemsAreRejected() {
        let problems = LoginItemsConfig(disable: ["com.microsoft.intuneMDMAgent.daemon", "com.microsoft.office.licensingV3.helper"]).validate()
        #expect(problems.count == 2)
    }

    @Test func disablesAppEmbeddedAgentForUser() throws {
        var disabled = false
        let shell = ScriptedShell { cmd in
            if cmd.hasPrefix("/bin/launchctl print-disabled") {
                return CommandResult(exitCode: 0, stdout: disabled ? "\"com.microsoft.teams2.agent\" => disabled" : "")
            }
            if cmd.hasPrefix("/bin/launchctl print gui/") { return CommandResult(exitCode: disabled ? 113 : 0) }
            if cmd.hasPrefix("/bin/launchctl disable") { disabled = true }
            return CommandResult(exitCode: 0)
        }
        let config = AgentConfig(configVersion: 1, loginItems: LoginItemsConfig(disable: ["com.microsoft.teams2.agent"]))
        let runner = try makeRunner(tempDir(), shell: shell, system: FakeSystem(), modules: [UserLoginItemsModule()])
        let opts = RunOptions(scope: .session, subject: "kellytaylor")
        #expect(runner.run(config: config, options: opts).results["login-items-user"] == .changed)
        #expect(runner.run(config: config, options: opts).results["login-items-user"] == .ok)
    }
}
