import Foundation
import SQLite3

public struct ModuleState: Equatable, Sendable {
    public var module: String
    public var subject: String
    public var configHash: String
    public var lastRun: Date
    public var result: RunResult
    public var duration: TimeInterval
    public var detail: String
    public var agentVersion: String
    /// Small per-module memory, e.g. which user device-name locked onto.
    public var data: [String: String]

    public init(module: String, subject: String, configHash: String, lastRun: Date, result: RunResult,
                duration: TimeInterval, detail: String, agentVersion: String, data: [String: String]) {
        self.module = module
        self.subject = subject
        self.configHash = configHash
        self.lastRun = lastRun
        self.result = result
        self.duration = duration
        self.detail = detail
        self.agentVersion = agentVersion
        self.data = data
    }
}

/// One row per (module, subject) in SQLite. Subject is "device" for device scope, the username otherwise.
public final class StateStore: @unchecked Sendable {
    private var db: OpaquePointer?

    /// `readOnly` is for viewers (status, the menu bar app) reading a store another user owns.
    public init(url: URL, readOnly: Bool = false) throws {
        if readOnly {
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
                sqlite3_close(db)
                throw ModuleError("cannot read state db \(url.path): \(message)")
            }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw ModuleError("cannot open state db \(url.path): \(message)")
        }
        try exec("""
            CREATE TABLE IF NOT EXISTS module_state (
                module TEXT NOT NULL, subject TEXT NOT NULL, config_hash TEXT NOT NULL,
                last_run REAL NOT NULL, result TEXT NOT NULL, duration REAL NOT NULL,
                detail TEXT NOT NULL, agent_version TEXT NOT NULL, data TEXT NOT NULL,
                PRIMARY KEY (module, subject))
            """)
    }

    deinit { sqlite3_close(db) }

    public func get(module: String, subject: String) -> ModuleState? {
        all(where: "module = ? AND subject = ?", [module, subject]).first
    }

    public func all() -> [ModuleState] { all(where: nil, []) }

    public func put(_ s: ModuleState) throws {
        let data = String(decoding: (try? JSONEncoder().encode(s.data)) ?? Data("{}".utf8), as: UTF8.self)
        try run("""
            INSERT OR REPLACE INTO module_state
            (module, subject, config_hash, last_run, result, duration, detail, agent_version, data)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [s.module, s.subject, s.configHash, s.lastRun.timeIntervalSince1970, s.result.rawValue,
                  s.duration, s.detail, s.agentVersion, data])
    }

    /// Forget one module's result for one subject.
    public func remove(module: String, subject: String) throws {
        try run("DELETE FROM module_state WHERE module = ? AND subject = ?", [module, subject])
    }

    /// Forget a module (or everything) so it re-applies on the next run.
    public func reset(module: String?) throws {
        if let module { try run("DELETE FROM module_state WHERE module = ?", [module]) }
        else { try run("DELETE FROM module_state", []) }
    }

    // MARK: - SQLite plumbing

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func prepare(_ sql: String, _ params: [Any]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as TimeInterval: sqlite3_bind_double(stmt, idx, v)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ params: [Any]) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
    }

    private func all(where clause: String?, _ params: [Any]) -> [ModuleState] {
        let sql = "SELECT module, subject, config_hash, last_run, result, duration, detail, agent_version, data "
            + "FROM module_state" + (clause.map { " WHERE \($0)" } ?? "") + " ORDER BY subject, module"
        guard let stmt = try? prepare(sql, params) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [ModuleState] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
            let data = (try? JSONDecoder().decode([String: String].self, from: Data(text(8).utf8))) ?? [:]
            rows.append(ModuleState(
                module: text(0), subject: text(1), configHash: text(2),
                lastRun: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                result: RunResult(rawValue: text(4)) ?? .fail,
                duration: sqlite3_column_double(stmt, 5), detail: text(6), agentVersion: text(7), data: data))
        }
        return rows
    }

    private func lastError() -> ModuleError {
        ModuleError("state db: " + String(cString: sqlite3_errmsg(db)))
    }
}
