import Foundation

public struct CommandResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
    public var trimmedOutput: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Every external command goes through this, so modules can be tested with a fake.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) -> CommandResult
}

public struct SystemCommandRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: 127, stderr: "could not start \(executable): \(error.localizedDescription)")
        }
        // Read before waiting so a chatty command can't fill the pipe and deadlock.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(exitCode: process.terminationStatus,
                             stdout: String(decoding: outData, as: UTF8.self),
                             stderr: String(decoding: errData, as: UTF8.self))
    }
}

extension CommandRunner {
    /// Run and throw a ModuleError carrying stderr if the command fails.
    @discardableResult
    public func check(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let result = run(executable, arguments)
        guard result.succeeded else {
            let name = (executable as NSString).lastPathComponent
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ModuleError("\(name) \(arguments.joined(separator: " ")) exited \(result.exitCode)"
                              + (detail.isEmpty ? "" : ": \(detail)"))
        }
        return result
    }
}
