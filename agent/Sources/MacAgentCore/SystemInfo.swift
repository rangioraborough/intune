import Foundation
import SystemConfiguration

public struct HardwareInfo: Equatable, Sendable {
    /// Marketing name, e.g. "MacBook Air".
    public var modelName: String
    public var serial: String

    public init(modelName: String, serial: String) {
        self.modelName = modelName
        self.serial = serial
    }
}

/// Facts about the Mac that modules read. Faked in tests.
public protocol SystemInfo: Sendable {
    /// Short name of the user at the GUI console, or nil at the login window.
    func consoleUser() -> String?
    func hardware() throws -> HardwareInfo
    func fileExists(_ path: String) -> Bool
    /// The account's full name ("Kelly Taylor"), if it has one.
    func fullName(of user: String) -> String?
    /// An app's CFBundleShortVersionString.
    func appVersion(_ path: String) -> String?
    /// When an app bundle was last installed or changed on this Mac, e.g. by an installer.
    func modified(_ path: String) -> Date?
}

public struct LiveSystemInfo: SystemInfo {
    let shell: CommandRunner

    public init(shell: CommandRunner) { self.shell = shell }

    public func consoleUser() -> String? {
        var uid: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String? else { return nil }
        return name == "loginwindow" || name.isEmpty ? nil : name
    }

    public func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Uses the status-change time (ctime): installers keep the vendor's build dates as the
    /// modification time, but can't backdate ctime, so this shows when the app actually landed.
    public func modified(_ path: String) -> Date? {
        var st = stat()
        guard stat(path + "/Contents/Info.plist", &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_ctimespec.tv_sec))
    }

    public func appVersion(_ path: String) -> String? {
        NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String
    }

    public func fullName(of user: String) -> String? {
        let r = shell.run("/usr/bin/id", ["-F", user])
        let name = r.trimmedOutput
        return r.succeeded && !name.isEmpty && name != user ? name : nil
    }

    public func hardware() throws -> HardwareInfo {
        let result = try shell.check("/usr/sbin/system_profiler", ["SPHardwareDataType", "-json"])
        struct Report: Decodable {
            struct Item: Decodable {
                let machine_name: String?
                let serial_number: String?
            }
            let SPHardwareDataType: [Item]
        }
        guard let item = (try? JSONDecoder().decode(Report.self, from: Data(result.stdout.utf8)))?
                .SPHardwareDataType.first,
              let model = item.machine_name else {
            throw ModuleError("system_profiler returned no model name")
        }
        return HardwareInfo(modelName: model, serial: item.serial_number ?? "")
    }
}
