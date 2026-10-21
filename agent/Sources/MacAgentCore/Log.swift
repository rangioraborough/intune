import Foundation

/// Plain-text log, one line per module per run:
///   2026-10-21T13:04:27+13:00 device  device-name     ok       0.4s  config=3f9a  detail
/// Rotated daily to <name>.YYYY-MM-DD, keeping `keepDays` days.
public final class AgentLog: @unchecked Sendable {
    private let url: URL
    private let keepDays: Int
    private let echo: Bool
    private let lock = NSLock()

    public init(url: URL, keepDays: Int = 14, echoToStdout: Bool = false) {
        self.url = url
        self.keepDays = keepDays
        self.echo = echoToStdout
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded()
    }

    static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    public func module(scope: Scope, id: String, result: String, duration: TimeInterval?,
                       configHash: String?, detail: String) {
        let dur = duration.map { String(format: "%.1fs", $0) } ?? "-"
        let hash = configHash.map { "config=\(String($0.prefix(4)))" } ?? ""
        let fields = [
            scope.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0),
            id.padding(toLength: 16, withPad: " ", startingAt: 0),
            result.padding(toLength: 8, withPad: " ", startingAt: 0),
            dur.padding(toLength: 7, withPad: " ", startingAt: 0),
            hash.padding(toLength: 12, withPad: " ", startingAt: 0),
            Self.oneLine(detail),
        ]
        write(fields.joined(separator: " "))
    }

    /// Agent-level events (start, config problems) that aren't tied to a module.
    public func event(scope: Scope, _ message: String) {
        write(scope.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0) + " " + Self.oneLine(message))
    }

    private func write(_ body: String) {
        let line = "\(Self.timestamp.string(from: Date())) \(body)\n"
        lock.lock(); defer { lock.unlock() }
        if echo { FileHandle.standardOutput.write(Data(line.utf8)) }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " | ").trimmingCharacters(in: .whitespaces)
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        if let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
           !Calendar.current.isDateInToday(modified) {
            let rotated = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).\(day.string(from: modified))")
            if !fm.fileExists(atPath: rotated.path) { try? fm.moveItem(at: url, to: rotated) }
        }
        let dir = url.deletingLastPathComponent()
        let cutoff = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date()) ?? .distantPast
        let prefix = url.lastPathComponent + "."
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(prefix) {
            if let date = day.date(from: String(name.dropFirst(prefix.count))), date < cutoff {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }
}
