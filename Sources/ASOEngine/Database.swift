import Foundation
import CSQLite

/// A value bound to or read from an SQL statement.
enum SQLValue: Sendable, Equatable {
    case int(Int)
    case double(Double)
    case text(String)
    case blob(Data)
    case null

    init(_ value: Int?) { self = value.map(SQLValue.int) ?? .null }
    init(_ value: Double?) { self = value.map(SQLValue.double) ?? .null }
    init(_ value: String?) { self = value.map(SQLValue.text) ?? .null }
    init(_ value: Data?) { self = value.map(SQLValue.blob) ?? .null }
    init(_ value: Date) { self = .double(value.timeIntervalSince1970) }
}

/// Thin wrapper over the SQLite C API. Not thread-safe by design: exactly one owner (the `Store` actor) uses it.
final class Database {
    private let handle: OpaquePointer

    /// Opens (creating if needed) the database at `path`; ":memory:" gives a private in-memory database.
    init(path: String) throws {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(db)
            throw EngineError.database("Cannot open the data file at \(path): \(message)")
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// Runs one or more statements that take no parameters.
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastError
            sqlite3_free(error)
            throw EngineError.database(message)
        }
    }

    /// Runs a statement and calls `row` for each result row.
    func query(_ sql: String, _ values: [SQLValue] = [], row: (Row) throws -> Void = { _ in }) throws {
        let statement = try Statement(database: handle, sql: sql)
        try statement.bind(values)
        while try statement.step() {
            try row(Row(statement: statement))
        }
    }

    /// Runs a statement and maps every result row.
    func rows<T>(_ sql: String, _ values: [SQLValue] = [], map: (Row) throws -> T) throws -> [T] {
        var result: [T] = []
        try query(sql, values) { result.append(try map($0)) }
        return result
    }

    /// Runs `body` in a transaction that is rolled back when it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var lastInsertID: Int { Int(sqlite3_last_insert_rowid(handle)) }
    var changes: Int { Int(sqlite3_changes(handle)) }

    var userVersion: Int {
        get throws { try rows("PRAGMA user_version") { $0.int(0) }.first ?? 0 }
    }

    func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    private var lastError: String { String(cString: sqlite3_errmsg(handle)) }
}

/// A prepared statement; finalized when released.
final class Statement {
    fileprivate let handle: OpaquePointer
    private let database: OpaquePointer

    init(database: OpaquePointer, sql: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw EngineError.database(String(cString: sqlite3_errmsg(database)))
        }
        self.handle = statement
        self.database = database
    }

    deinit {
        sqlite3_finalize(handle)
    }

    /// SQLite copies bound text and blobs before the call returns (SQLITE_TRANSIENT).
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    func bind(_ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .int(let v): rc = sqlite3_bind_int64(handle, index, sqlite3_int64(v))
            case .double(let v): rc = sqlite3_bind_double(handle, index, v)
            case .text(let v): rc = sqlite3_bind_text(handle, index, v, -1, Self.transient)
            case .blob(let v):
                rc = v.isEmpty
                    ? sqlite3_bind_zeroblob(handle, index, 0)
                    : v.withUnsafeBytes { sqlite3_bind_blob(handle, index, $0.baseAddress, Int32($0.count), Self.transient) }
            case .null: rc = sqlite3_bind_null(handle, index)
            }
            guard rc == SQLITE_OK else { throw EngineError.database(String(cString: sqlite3_errmsg(database))) }
        }
    }

    /// Advances to the next row; false when the statement is done.
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw EngineError.database(String(cString: sqlite3_errmsg(database)))
        }
    }
}

/// The current row of a statement, read by column index.
struct Row {
    fileprivate let statement: Statement

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement.handle, column) == SQLITE_NULL }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement.handle, column)) }
    func optionalInt(_ column: Int32) -> Int? { isNull(column) ? nil : int(column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement.handle, column) }
    func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }
    func date(_ column: Int32) -> Date { Date(timeIntervalSince1970: double(column)) }

    func text(_ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement.handle, column) else { return "" }
        return String(cString: pointer)
    }

    func optionalText(_ column: Int32) -> String? { isNull(column) ? nil : text(column) }

    func blob(_ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement.handle, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement.handle, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    func optionalBlob(_ column: Int32) -> Data? { isNull(column) ? nil : blob(column) }
}
