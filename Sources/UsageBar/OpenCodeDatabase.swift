import Foundation
import SQLite3

/// Read-only windowed spend from the OpenCode local database.
/// Opens the file with `SQLITE_OPEN_URI | SQLITE_OPEN_READONLY`; never writes.
struct OpenCodeSpend {
    var fiveHour: Double
    var week: Double
    var month: Double
}

struct OpenCodePace {
    /// Dollars per hour over the last 30 minutes.
    var recentPerHour: Double
    /// Typical dollars per active hour (median, past 14 days), if known.
    var usualPerHour: Double?
}

struct OpenCodeDBSnapshot {
    var spend: OpenCodeSpend
    /// Go spend recorded after the snapshot's `since` moment.
    var spentSince: Double
    /// Go refused a request ("usage limit exceeded") after `since`.
    var limitHit: Bool
}

enum OpenCodeDatabase {
    static var databasePath: String {
        usageBarHome.appendingPathComponent(".local/share/opencode/opencode.db").path
    }

    static func available() -> Bool {
        FileManager.default.fileExists(atPath: databasePath)
    }

    static func readSpend(now: Date) -> OpenCodeSpend? {
        snapshot(now: now, since: now)?.spend
    }

    /// Everything one refresh needs from the database, read through a single
    /// connection: the rolling Go spend windows, the Go spend recorded after
    /// `since` (gross, so spend ageing out of a window can't mask new use), and
    /// whether Go has refused requests since then.
    static func snapshot(now: Date, since: Date) -> OpenCodeDBSnapshot? {
        let path = databasePath
        guard FileManager.default.fileExists(atPath: path), let db = open(path) else { return nil }
        defer { sqlite3_close(db) }

        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let sinceMs = Int64(since.timeIntervalSince1970 * 1000)
        let fiveMs = nowMs - 5 * 3600 * 1000
        let weekMs = nowMs - 7 * 24 * 3600 * 1000
        let monthMs = nowMs - 30 * 24 * 3600 * 1000

        let spendSQL = """
        select \
          coalesce(sum(case when time_created > ?1 then c end),0), \
          coalesce(sum(case when time_created > ?2 then c end),0), \
          coalesce(sum(case when time_created > ?3 then c end),0), \
          coalesce(sum(case when time_created > ?4 then c end),0) \
        from (select time_created, json_extract(data,'$.cost') c from session_message \
              where type='assistant' and json_extract(data,'$.model.providerID')='opencode-go' \
              and time_created > min(?3, ?4) and time_created <= ?5)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, spendSQL, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        // Upper bound: rows dated in the future (clock moved back) aren't "recent".
        for (index, value) in [fiveMs, weekMs, monthMs, sinceMs, nowMs].enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), value)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let spend = OpenCodeSpend(
            fiveHour: sqlite3_column_double(statement, 0),
            week: sqlite3_column_double(statement, 1),
            month: sqlite3_column_double(statement, 2)
        )
        return OpenCodeDBSnapshot(
            spend: spend,
            spentSince: sqlite3_column_double(statement, 3),
            limitHit: goLimitHit(db: db, sinceMs: sinceMs, nowMs: nowMs)
        )
    }

    /// Spend pace on OpenCode Go in dollars per hour: the last 30 minutes,
    /// against your usual rate — the median of the past 14 days' hours in
    /// which you spent anything (so idle hours don't drag "usual" down). The
    /// current hour is excluded from "usual". `usual` is nil until there are
    /// at least 5 such hours.
    static func pace(now: Date) -> OpenCodePace? {
        let path = databasePath
        guard FileManager.default.fileExists(atPath: path), let db = open(path) else { return nil }
        defer { sqlite3_close(db) }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let hourMs: Int64 = 3_600_000
        let currentHour = nowMs / hourMs * hourMs

        // "Usual" only changes when an hour completes, so it is computed once
        // per hour; each refresh only sums the last 30 minutes.
        paceLock.lock()
        var usual = usualCache?.hour == currentHour ? usualCache?.value : nil
        let cached = usualCache?.hour == currentHour
        paceLock.unlock()
        if !cached {
            usual = usualPerHour(db: db, currentHour: currentHour, hourMs: hourMs)
            paceLock.lock()
            usualCache = (currentHour, usual)
            paceLock.unlock()
        }

        let recentSQL = """
        select coalesce(sum(json_extract(data,'$.cost')),0) from session_message \
        where type='assistant' and json_extract(data,'$.model.providerID')='opencode-go' \
          and time_created > ?1 and time_created <= ?2
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, recentSQL, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, nowMs - hourMs / 2)
        sqlite3_bind_int64(statement, 2, nowMs)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return OpenCodePace(recentPerHour: sqlite3_column_double(statement, 0) * 2, usualPerHour: usual)
    }

    private static let paceLock = NSLock()
    private static var usualCache: (hour: Int64, value: Double?)?

    /// Median of the past 14 days' completed hours with any Go spend.
    private static func usualPerHour(db: OpaquePointer, currentHour: Int64, hourMs: Int64) -> Double? {
        let sql = """
        select time_created / ?1 as h, sum(coalesce(json_extract(data,'$.cost'),0)) from session_message \
        where type='assistant' and json_extract(data,'$.model.providerID')='opencode-go' \
          and time_created > ?2 and time_created < ?3 \
        group by h
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, hourMs)
        sqlite3_bind_int64(statement, 2, currentHour - 14 * 24 * hourMs)
        sqlite3_bind_int64(statement, 3, currentHour)
        var hourly: [Double] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let spent = sqlite3_column_double(statement, 1)
            if spent >= 0.01 { hourly.append(spent) }
        }
        guard hourly.count >= 5 else { return nil }
        hourly.sort()
        let mid = hourly.count / 2
        return hourly.count % 2 == 0 ? (hourly[mid - 1] + hourly[mid]) / 2 : hourly[mid]
    }

    /// True when the newest OpenCode Go response since `sinceMs` failed with
    /// Go's own "usage limit exceeded" error — the plan is exhausted right now,
    /// whatever the last console reading said. Only assistant responses count,
    /// so bookkeeping records (e.g. a model switch) can't hide the failure.
    private static func goLimitHit(db: OpaquePointer, sinceMs: Int64, nowMs: Int64) -> Bool {
        let sql = """
        select coalesce(json_extract(data,'$.error.message'),'') from session_message \
        where type='assistant' and json_extract(data,'$.model.providerID')='opencode-go' and time_created > ?1 \
          and time_created <= ?2 \
        order by time_created desc limit 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sinceMs)
        sqlite3_bind_int64(statement, 2, nowMs)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return false }
        return String(cString: text).lowercased().contains("usage limit")
    }

    private static func open(_ path: String) -> OpaquePointer? {
        var components = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        guard let uri = components.string else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_URI | SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        return db
    }
}
