import Foundation
import SQLite3

/// A thin error-bearing wrapper over the system SQLite C API.
enum SQLiteError: Error {
    case open(String, String)
    case prepare(String, String)
    case bind(String, String)
    case step(String, String)
    case exec(String, String)
    case busy(String)
}

/// Owns a single database connection and closes it on deallocation.
final class Database {
    private(set) var handle: OpaquePointer?

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if db != nil { sqlite3_close(db) }
            throw SQLiteError.open(path, message)
        }
        handle = db
        // Failing fast on constraints and treating busy as an explicit error
        // keeps import transactions honest.
        try exec("PRAGMA foreign_keys = ON")
        try exec("PRAGMA busy_timeout = 5000")
    }

    deinit {
        sqlite3_close(handle)
    }

    @discardableResult
    func exec(_ sql: String) throws -> Self {
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorPointer)
            throw SQLiteError.exec(sql, message)
        }
        return self
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) != SQLITE_OK {
            throw SQLiteError.prepare(sql, String(cString: sqlite3_errmsg(handle)))
        }
        return Statement(handle: statement!, database: self, sql: sql)
    }

    var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    var changes: Int {
        Int(sqlite3_changes(handle))
    }

    func errorMessage() -> String {
        String(cString: sqlite3_errmsg(handle))
    }
}

/// A prepared statement. Values are rebound on every use; call `reset()` before
/// reusing a statement more than once.
final class Statement {
    private let handle: OpaquePointer
    private let database: Database
    private let sql: String

    fileprivate init(handle: OpaquePointer, database: Database, sql: String) {
        self.handle = handle
        self.database = database
        self.sql = sql
    }

    deinit {
        sqlite3_finalize(handle)
    }

    /// Binds parameters by 1-based index. `nil` binds NULL; `Int64`, `String`
    /// and `Data` cover everything the catalog stores.
    func bind(_ values: Any?...) throws {
        sqlite3_clear_bindings(handle)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .none:
                code = sqlite3_bind_null(handle, index)
            case let integer as Int64:
                code = sqlite3_bind_int64(handle, index, integer)
            case let integer as Int:
                code = sqlite3_bind_int64(handle, index, Int64(integer))
            case let text as String:
                code = sqlite3_bind_text(handle, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let data as Data:
                code = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(handle, index, bytes.baseAddress, Int32(bytes.count),
                                      unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            default:
                throw SQLiteError.bind(sql, "unsupported parameter type")
            }
            if code != SQLITE_OK {
                throw SQLiteError.bind(sql, database.errorMessage())
            }
        }
    }

    /// Advances the statement; returns `true` for SQLITE_ROW, `false` for
    /// SQLITE_DONE.
    @discardableResult
    func step() throws -> Bool {
        let code = sqlite3_step(handle)
        if code == SQLITE_ROW { return true }
        sqlite3_reset(handle)
        if code == SQLITE_DONE { return false }
        if code == SQLITE_BUSY || code == SQLITE_LOCKED {
            throw SQLiteError.busy(database.errorMessage())
        }
        throw SQLiteError.step(sql, database.errorMessage())
    }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    func string(_ column: Int32) -> String {
        if let pointer = sqlite3_column_text(handle, column) {
            return String(cString: pointer)
        }
        return ""
    }
}

/// Runs `work` inside a deferred transaction. A thrown error rolls back; a
/// normal return commits. Both paths restore autocommit mode.
func withTransaction<T>(_ database: Database, _ work: () throws -> T) throws -> T {
    try database.exec("BEGIN IMMEDIATE")
    do {
        let result = try work()
        try database.exec("COMMIT")
        return result
    } catch {
        do { try database.exec("ROLLBACK") } catch { }
        throw error
    }
}
