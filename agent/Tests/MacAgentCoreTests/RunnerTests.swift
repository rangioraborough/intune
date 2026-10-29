import Foundation
import Testing
@testable import MacAgentCore

@Suite struct RunnerTests {
    @Test func unconfiguredModuleDropsItsOldResult() throws {
        let configured = AgentConfig(configVersion: 1, deviceName: DeviceNameConfig())
        let runner = try makeRunner(tempDir(), shell: FakeScutil([:]), system: FakeSystem(user: "annabellesimpson"))
        _ = runner.run(config: configured, options: RunOptions(scope: .device, subject: "device"))
        #expect(runner.state.get(module: "device-name", subject: "device") != nil)
        _ = runner.run(config: AgentConfig(configVersion: 1), options: RunOptions(scope: .device, subject: "device"))
        #expect(runner.state.get(module: "device-name", subject: "device") == nil)
    }
}
