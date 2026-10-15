import Foundation
import SQLite3

/// Read-only windowed spend from the OpenCode local database.
/// Opens the file with `SQLITE_OPEN_URI | SQLITE_OPEN_READONLY`; never writes.
struct OpenCodeSpend {
    var fiveHour: Double
    var week: Double
    var month: Double
}

enum OpenCodeDatabase {
    static var databasePath: String {
        usageBarHome.appendingPathComponent(".local/share/opencode/opencode.db").path
    }

    static func available() -> Bool {
        FileManager.default.fileExists(atPath: databasePath)
    }

    static func readSpend(now: Date) -> OpenCodeSpend? {
        let path = databasePath
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var db: OpaquePointer?
        var components = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        guard let uri = components.string else { return nil }
        let flags = SQLITE_OPEN_URI | SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        select coalesce(sum(json_extract(data,'$.cost')),0) from session_message \
        where json_extract(data,'$.model.providerID')='opencode-go' and time_created > ?
        """

        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let fiveHour = sum(db: db, sql: sql, sinceMs: nowMs - 5 * 3600 * 1000)
        let week = sum(db: db, sql: sql, sinceMs: nowMs - 7 * 24 * 3600 * 1000)
        let month = sum(db: db, sql: sql, sinceMs: nowMs - 30 * 24 * 3600 * 1000)

        guard let fiveHour, let week, let month else { return nil }
        return OpenCodeSpend(fiveHour: fiveHour, week: week, month: month)
    }

    private static func sum(db: OpaquePointer, sql: String, sinceMs: Int64) -> Double? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, sinceMs)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_double(statement, 0)
    }
}
