import Foundation
import CSQLite

public enum DatabaseFailure: Error, LocalizedError {
    case unavailable(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

/// Holds a read-only connection. Never alters the database, its settings, or system notifications.
public final class NotificationDatabase {
    private var db: OpaquePointer?
    private var signatures: [Int64: String] = [:]
    private var primed = false
    private var lastVersion: Int64?
    private var identity: String?
    private var hasDeliveredDate = false
    private var baseline: [Notice] = []
    public let path: URL

    public init(path: URL) { self.path = path }
    deinit { if let db { sqlite3_close(db) } }

    /// Transient startup/replacement snapshot for suppressing historical UI cards.
    public func takeBaseline() -> [Notice] {
        defer { baseline = [] }
        return baseline
    }

    public func poll() throws -> [Notice] {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        let currentIdentity = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
        if identity != currentIdentity {
            if let db { sqlite3_close(db) }
            db = nil; primed = false; lastVersion = nil; signatures = [:]
            identity = currentIdentity
        }
        if db == nil { try open() }
        let version = try scalar("PRAGMA data_version")
        if lastVersion == version { return [] }
        var statement: OpaquePointer?
        let dateColumn = hasDeliveredDate ? "delivered_date" : "NULL"
        guard sqlite3_prepare_v2(db, "SELECT rec_id, data, \(dateColumn) FROM record ORDER BY rec_id", -1, &statement, nil) == SQLITE_OK else {
            throw failure("不支持此版本的通知数据库")
        }
        defer { sqlite3_finalize(statement) }
        var next: [Int64: String] = [:]
        var notices: [Notice] = [], existing: [Notice] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let recordID = sqlite3_column_int64(statement, 0)
            let count = Int(sqlite3_column_bytes(statement, 1))
            let dateType = sqlite3_column_type(statement, 2)
            let timestamp = sqlite3_column_double(statement, 2)
            let deliveredAt = (dateType == SQLITE_FLOAT || dateType == SQLITE_INTEGER) && timestamp.isFinite && timestamp > 0
                && timestamp <= Date().timeIntervalSinceReferenceDate + 86_400
                ? Date(timeIntervalSinceReferenceDate: timestamp) : nil
            if count > 0, count <= 1_048_576, let bytes = sqlite3_column_blob(statement, 1),
               let notice = PayloadParser.parse(Data(bytes: bytes, count: count), recordID: recordID, deliveredAt: deliveredAt) {
                next[recordID] = notice.id
                if primed && signatures[recordID] != notice.id { notices.append(notice) }
                if !primed { existing.append(notice) }
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw failure("通知数据库读取失败") }
        if !primed { baseline = existing }
        signatures = next; primed = true; lastVersion = version
        return notices
    }

    private func open() throws {
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(path.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard result == SQLITE_OK else {
            let detail = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开"
            if let connection { sqlite3_close(connection) }
            throw DatabaseFailure.unavailable(detail)
        }
        db = connection
        sqlite3_busy_timeout(db, 150)
        guard sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            let error = failure("无法进入只读模式")
            sqlite3_close(db); db = nil
            throw error
        }
        // Prepare now so a permission/schema failure is reported before calling the source healthy.
        var statement: OpaquePointer?
        let checked = sqlite3_prepare_v2(db, "SELECT rec_id, data FROM record LIMIT 0", -1, &statement, nil)
        sqlite3_finalize(statement)
        guard checked == SQLITE_OK else {
            let error = failure("无法读取通知记录")
            sqlite3_close(db); db = nil
            throw error
        }
        // Older schemas may omit the system delivery time. Keep those readable.
        hasDeliveredDate = sqlite3_table_column_metadata(db, nil, "record", "delivered_date", nil, nil, nil, nil, nil) == SQLITE_OK
    }

    private func scalar(_ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure("读取状态失败") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure("读取状态失败") }
        return sqlite3_column_int64(statement, 0)
    }

    private func failure(_ context: String) -> DatabaseFailure {
        .unavailable("\(context)：\(db.map { String(cString: sqlite3_errmsg($0)) } ?? "未连接")")
    }

    public static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var paths = [home.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")]
        var buffer = [CChar](repeating: 0, count: 4096)
        if confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0 {
            paths.append(URL(fileURLWithPath: String(cString: buffer)).appendingPathComponent("com.apple.notificationcenter/db2/db"))
        }
        return paths
    }
}
