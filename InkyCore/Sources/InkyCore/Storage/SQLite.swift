import Foundation
import SQLite3

/// A value SQLite stores, or is asked for.
enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    static func integer(_ value: Int) -> SQLiteValue { .integer(Int64(value)) }
    static func date(_ date: Date) -> SQLiteValue { .real(date.timeIntervalSince1970) }

    /// The text, or null where there is none.
    static func optional(_ text: String?) -> SQLiteValue {
        text.map(SQLiteValue.text) ?? .null
    }
}

struct SQLiteError: Error, CustomStringConvertible {
    var code: Int32
    var message: String

    var description: String { "SQLite \(code): \(message)" }
}

/// The row a query is at. Columns count from 0, in the order they were asked for.
struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    func optionalInt(_ column: Int32) -> Int? {
        isNull(column) ? nil : int(column)
    }

    func bool(_ column: Int32) -> Bool {
        sqlite3_column_int64(statement, column) != 0
    }

    func date(_ column: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    func optionalDate(_ column: Int32) -> Date? {
        isNull(column) ? nil : date(column)
    }

    func text(_ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    func data(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}

/// The SQLite that comes with macOS, with as little on top as it takes to
/// use it from Swift. One database is used from one place at a time: whoever
/// owns it sees to that.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    /// Statements are compiled once and kept, by what they say.
    private var statements: [String: OpaquePointer] = [:]

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// What is written with values in it comes in many shapes. Past this
    /// many, the kept statements are let go and collected again.
    private static let maxStatements = 64

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let error = lastError
            sqlite3_close(handle)
            handle = nil
            throw error
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit {
        for statement in statements.values {
            sqlite3_finalize(statement)
        }
        sqlite3_close(handle)
    }

    private var lastError: SQLiteError {
        SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Runs statements that take no values and give none, such as a schema.
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError }
    }

    /// Runs a statement that changes something. Returns how many rows it changed.
    @discardableResult
    func run(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int {
        let statement = try prepare(sql, values)
        defer { sqlite3_reset(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError }
        return Int(sqlite3_changes(handle))
    }

    /// Runs a query and reads each of its rows with `read`.
    func query<T>(_ sql: String, _ values: [SQLiteValue] = [], _ read: (SQLiteRow) -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        defer { sqlite3_reset(statement) }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(read(SQLiteRow(statement: statement)))
            case SQLITE_DONE: return rows
            default: throw lastError
            }
        }
    }

    /// The id of the row that was inserted last.
    var lastInsertedID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    /// Runs `body` so that all of it happens, or none of it.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ values: [SQLiteValue]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let kept = statements[sql] {
            statement = kept
        } else {
            var compiled: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &compiled, nil) == SQLITE_OK, let compiled else {
                throw lastError
            }
            if statements.count >= Self.maxStatements {
                for kept in statements.values {
                    sqlite3_finalize(kept)
                }
                statements.removeAll(keepingCapacity: true)
            }
            statements[sql] = compiled
            statement = compiled
        }

        sqlite3_clear_bindings(statement)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status = switch value {
            case .null:
                sqlite3_bind_null(statement, index)
            case .integer(let integer):
                sqlite3_bind_int64(statement, index, integer)
            case .real(let real):
                sqlite3_bind_double(statement, index, real)
            case .text(let text):
                sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .blob(let data):
                data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
                }
            }
            guard status == SQLITE_OK else { throw lastError }
        }
        return statement
    }
}
