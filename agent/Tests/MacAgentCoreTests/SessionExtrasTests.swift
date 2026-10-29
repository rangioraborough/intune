import Foundation
import Testing
@testable import MacAgentCore

private func session(_ user: String = "annabellesimpson") -> RunOptions { RunOptions(scope: .session, subject: user) }

@Suite struct WallpaperTests {
    @Test func setsOnceThenLeavesUserChoice() throws {
        let tmp = tempDir()
        let p = testPaths(tmp)
        let image = p.siteResources.appendingPathComponent("wallpaper/bg.jpg")
        let desktop = FakeDesktop()
        let config = AgentConfig(configVersion: 1, wallpaper: WallpaperConfig(image: "wallpaper/bg.jpg"))
        let runner = try makeRunner(tmp, shell: FakeShell(), system: FakeSystem(files: [image.path]), modules: [WallpaperModule(desktop: desktop)])
        #expect(runner.run(config: config, options: session()).results["wallpaper"] == .changed)
        #expect(desktop.current == image)
        desktop.current = URL(fileURLWithPath: "/Users/a/cat.jpg")
        #expect(runner.run(config: config, options: session()).results["wallpaper"] == nil)   // once: not run again
        #expect(desktop.current?.lastPathComponent == "cat.jpg")
    }
}

@Suite struct DefaultBrowserTests {
    let chrome = "/Applications/Google Chrome.app"

    @Test func asksOnceAndRespectsNo() throws {
        let desktop = FakeDesktop()
        desktop.browser = URL(fileURLWithPath: "/Applications/Safari.app")
        desktop.answer = .declined
        let config = AgentConfig(configVersion: 1, defaultBrowser: DefaultBrowserConfig(app: chrome))
        let runner = try makeRunner(tempDir(), shell: FakeShell(), system: FakeSystem(files: [chrome]),
                                    modules: [DefaultBrowserModule(desktop: desktop)])
        #expect(runner.run(config: config, options: session()).results["default-browser"] == .ok)
        _ = runner.run(config: config, options: session())
        #expect(desktop.asked == 1)
    }

    @Test func noAnswerAsksAgainNextTime() throws {
        let desktop = FakeDesktop()
        desktop.answer = .noAnswer
        let config = AgentConfig(configVersion: 1, defaultBrowser: DefaultBrowserConfig(app: chrome))
        let runner = try makeRunner(tempDir(), shell: FakeShell(), system: FakeSystem(files: [chrome]),
                                    modules: [DefaultBrowserModule(desktop: desktop)])
        #expect(runner.run(config: config, options: session()).results["default-browser"] == .waiting)
        desktop.answer = .agreed
        #expect(runner.run(config: config, options: session()).results["default-browser"] == .waiting)
        #expect(desktop.asked == 1)   // not asked again straight away
        var forced = session()
        forced.force = true
        #expect(runner.run(config: config, options: forced).results["default-browser"] == .changed)
        #expect(desktop.asked == 2)
    }

    @Test func waitsForChrome() throws {
        let desktop = FakeDesktop()
        let config = AgentConfig(configVersion: 1, defaultBrowser: DefaultBrowserConfig(app: chrome))
        let runner = try makeRunner(tempDir(), shell: FakeShell(), system: FakeSystem(), modules: [DefaultBrowserModule(desktop: desktop)])
        #expect(runner.run(config: config, options: session()).results["default-browser"] == .waiting)
        #expect(desktop.asked == 0)
    }
}

@Suite struct PrinterPresetTests {
    func preset(code: String) -> NSDictionary {
        [PrinterDetails.settingsKey: [
            PrinterDetails.keyPrefix + "JBAUserIDTextEditReference": code,
            PrinterDetails.keyPrefix + "JBAUserIDTextEditTicket": code,
            "com.apple.print.preset.Duplex": "None",
        ]] as NSDictionary
    }

    @Test func copiesMissingPresetsAndSeedsDefault() throws {
        let tmp = tempDir()
        let p = testPaths(tmp)
        let file = p.siteResources.appendingPathComponent("printers/presets.plist")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let template: NSDictionary = ["Colour - Secure": preset(code: ""), "Mono": preset(code: "")]
        try PropertyListSerialization.data(fromPropertyList: template, format: .xml, options: 0).write(to: file)

        let prefs = FakePrefs()
        prefs.set("Mono", preset(code: "1234"), domain: PrinterDetails.presetsDomain)   // user already has one
        let shell = ScriptedShell { cmd in
            cmd == "/usr/bin/lpstat -d" ? CommandResult(exitCode: 0, stdout: "no system default destination") : CommandResult(exitCode: 0)
        }
        let config = AgentConfig(configVersion: 1, printers: PrintersConfig(ppd: "/x", queues: [.init(name: "Ruru_Copier", uri: "lpd://1/")],
                                                                            defaultQueue: "Ruru_Copier", presets: "printers/presets.plist"))
        let runner = try makeRunner(tmp, shell: shell, system: FakeSystem(), prefs: prefs, modules: [PrinterPresetsModule()])
        #expect(runner.run(config: config, options: session()).results["printer-presets"] == .changed)
        #expect(prefs.value("Colour - Secure", domain: PrinterDetails.presetsDomain) != nil)
        let mono = prefs.value("Mono", domain: PrinterDetails.presetsDomain) as? [String: Any]
        #expect((mono?[PrinterDetails.settingsKey] as? [String: Any])?[PrinterDetails.keyPrefix + "JBAUserIDTextEditReference"] as? String == "1234")
        #expect(shell.calls.contains("/usr/bin/lpoptions -d Ruru_Copier"))
    }

    @Test func printerDetailsReplacesOnlyExistingKeys() throws {
        let prefs = FakePrefs()
        prefs.set("Mono", preset(code: "old"), domain: PrinterDetails.presetsDomain)
        prefs.set("Plain", [PrinterDetails.settingsKey: ["com.apple.print.preset.Duplex": "None"]] as NSDictionary,
                  domain: PrinterDetails.presetsDomain)
        let perPrinter = "com.apple.print.custompresets.forprinter.Ruru_Copier"
        prefs.set(PrinterDetails.lastUsedKey, [PrinterDetails.keyPrefix + "JBAUserIDTextEditTicket": "old"] as NSDictionary, domain: perPrinter)

        let count = try PrinterDetails.apply(name: "", code: "5678", prefs: prefs, perPrinter: [perPrinter])
        #expect(count == 1)
        let mono = (prefs.value("Mono", domain: PrinterDetails.presetsDomain) as? [String: Any])?[PrinterDetails.settingsKey] as? [String: Any]
        #expect(mono?[PrinterDetails.keyPrefix + "JBAUserIDTextEditReference"] as? String == "5678")
        let plain = (prefs.value("Plain", domain: PrinterDetails.presetsDomain) as? [String: Any])?[PrinterDetails.settingsKey] as? [String: Any]
        #expect(plain?.count == 1)   // no accounting keys added where there were none
        #expect((prefs.value(PrinterDetails.lastUsedKey, domain: perPrinter) as? [String: Any])?[PrinterDetails.keyPrefix + "JBAUserIDTextEditTicket"] as? String == "5678")
    }
}

@Suite struct OneSidedTests {
    @Test func presetSettingsRewriteEveryPresetAndLastUsed() throws {
        let prefs = FakePrefs()
        let two: NSDictionary = [PrinterDetails.settingsKey: ["com.apple.print.PrintSettings.PMDuplexing": 2,
                                                             PrinterDetails.keyPrefix + "JBAUserIDTextEditReference": "1234"]]
        prefs.set("Colour", two, domain: PrinterDetails.presetsDomain)
        prefs.set("B&W", two, domain: PrinterDetails.presetsDomain)
        let pp = "com.apple.print.custompresets.forprinter.Ruru_Copier"
        prefs.set(PrinterDetails.lastUsedKey, ["Duplex": "DuplexNoTumble"] as NSDictionary, domain: pp)
        let n = try PrinterPresetsModule.applySettings(["com.apple.print.PrintSettings.PMDuplexing": .int(1), "Duplex": .string("None")],
                                                       prefs: prefs, perPrinter: [pp], dryRun: false)
        #expect(n == 3)
        let colour = (prefs.value("Colour", domain: PrinterDetails.presetsDomain) as? [String: Any])?[PrinterDetails.settingsKey] as? [String: Any]
        #expect(colour?["com.apple.print.PrintSettings.PMDuplexing"] as? Int == 1)
        #expect(colour?[PrinterDetails.keyPrefix + "JBAUserIDTextEditReference"] as? String == "1234")   // teacher's code kept
        #expect((prefs.value(PrinterDetails.lastUsedKey, domain: pp) as? [String: Any])?["Duplex"] as? String == "None")
    }

    @Test func readsQueueDefaultFromLpoptions() {
        let listing = "PageSize/Media Size: Letter *A4\nDuplex/2-Sided Printing: *DuplexNoTumble None DuplexTumble\n"
        #expect(PrinterQueuesModule.currentDefault(of: "Duplex", in: listing) == "DuplexNoTumble")
        #expect(PrinterQueuesModule.currentDefault(of: "PageSize", in: listing) == "A4")
        #expect(PrinterQueuesModule.currentDefault(of: "Nope", in: listing) == nil)
    }
}
