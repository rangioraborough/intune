import Foundation
import Testing
@testable import MacAgentCore

private func plist(_ body: String) -> Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>\(body)</dict></plist>
    """.utf8)
}

@Suite struct ConfigTests {
    @Test func decodesPascalCaseKeys() throws {
        let data = plist("""
            <key>ConfigVersion</key><integer>3</integer>
            <key>ExcludedUsers</key><array><string>itadmin</string></array>
            <key>DeviceName</key><dict>
              <key>Template</key><string>{model}-{serial}</string>
              <key>ModelCodes</key><dict><key>MacBook Neo</key><string>MBN</string></dict>
            </dict>
            """)
        let config = try ConfigLoader.decode(data: data, source: "test").get()
        #expect(config.configVersion == 3)
        #expect(config.allExcludedUsers.contains("itadmin"))
        #expect(config.allExcludedUsers.contains("root"))
        #expect(config.deviceName?.resolvedTemplate == "{model}-{serial}")
        #expect(config.deviceName?.modelCodes?["MacBook Neo"] == "MBN")
    }

    @Test func missingVersionNamesTheKey() {
        guard case .failure(let e) = ConfigLoader.decode(data: plist(""), source: "test") else {
            Issue.record("expected failure"); return
        }
        #expect(e.message.contains("ConfigVersion"))
    }

    @Test func wrongTypeNamesThePath() {
        let data = plist("""
            <key>ConfigVersion</key><integer>1</integer>
            <key>DeviceName</key><dict><key>Template</key><integer>5</integer></dict>
            """)
        guard case .failure(let e) = ConfigLoader.decode(data: data, source: "test") else {
            Issue.record("expected failure"); return
        }
        #expect(e.message.contains("DeviceName.Template"))
    }

    @Test func rejectsUnknownPlaceholder() {
        let data = plist("""
            <key>ConfigVersion</key><integer>1</integer>
            <key>DeviceName</key><dict><key>Template</key><string>{model}-{room}</string></dict>
            """)
        guard case .failure(let e) = ConfigLoader.decode(data: data, source: "test") else {
            Issue.record("expected failure"); return
        }
        #expect(e.message.contains("unknown placeholder"))
    }

    @Test func fallsBackToCacheWhenManagedConfigBreaks() throws {
        let dir = tempDir()
        let p = testPaths(dir)
        let loader = ConfigLoader(paths: p)
        try plist("<key>ConfigVersion</key><integer>7</integer>").write(to: p.managedConfig)
        guard case .loaded(_, .managed) = loader.load(updateCache: true) else { Issue.record("should load"); return }

        try Data("not a plist".utf8).write(to: p.managedConfig)
        guard case .loaded(let cached, .cache) = loader.load(updateCache: true) else {
            Issue.record("should fall back to cache"); return
        }
        #expect(cached.configVersion == 7)
    }

    @Test func unavailableWithNothingAnywhere() {
        let loader = ConfigLoader(paths: testPaths(tempDir()))
        guard case .unavailable = loader.load(updateCache: true) else { Issue.record("expected unavailable"); return }
    }

    @Test func hashIgnoresDictionaryOrder() {
        let a = ConfigHash.of(["b": "2", "a": "1", "c": "3"])
        let b = ConfigHash.of(["c": "3", "a": "1", "b": "2"])
        #expect(a == b)
    }
}

@Suite struct StatusReportTests {
    func state(_ module: String, _ result: RunResult, _ minutesAgo: Double) -> ModuleState {
        ModuleState(module: module, subject: "x", configHash: "h", lastRun: Date(timeIntervalSinceNow: -minutesAgo * 60),
                    result: result, duration: 0, detail: "d", agentVersion: "t", data: [:])
    }

    @Test func hidesHousekeepingAndCountsProblems() {
        let report = StatusReport(states: [state("dock", .changed, 5), state("legacy-cleanup", .fail, 1),
                                           state("device-name", .fail, 10)])
        #expect(report.rows.map(\.title) == ["Computer name", "Dock"])
        #expect(report.headline == "MacAgent \(AgentVersion.current) · 1 issue")
        #expect(StatusReport(states: []).issueSummary == "Waiting for first check")
        #expect(abs(report.lastChecked!.timeIntervalSinceNow + 60) < 5)
    }

    @Test func menuBarValidation() {
        let bad = MenuBarConfig(helpTitle: "Contact IT", items: [.init(title: "Portal", url: "portal.school.nz")])
        let problems = bad.validate()
        #expect(problems.contains { $0.contains("HelpURL") })
        #expect(problems.contains { $0.contains("not a full URL") })
        #expect(MenuBarConfig(helpTitle: "IT", helpURL: "mailto:it@school.nz",
                              items: [.init(title: "Portal", url: "https://portal.school.nz", app: "Google Chrome")])
                    .validate().isEmpty)
    }
}
