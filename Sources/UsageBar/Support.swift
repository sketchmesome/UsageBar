import Foundation
import CoreFoundation

// MARK: - Shared constants

let usageBarHome = FileManager.default.homeDirectoryForCurrentUser

// MARK: - Formatting helpers

func fmtDecimal(_ d: Double, _ decimals: Int) -> String {
    String(format: "%.\(decimals)f", d)
}

/// Amount without a currency symbol, e.g. `3.90`.
func amount(_ d: Double) -> String {
    String(format: "%.2f", d)
}

func clockTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm"
    return f.string(from: date)
}

func weekdayTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE HH:mm"
    return f.string(from: date)
}

func shortDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "MMM d"
    return f.string(from: date)
}

/// Unambiguous calendar date (yyyy-MM-dd), used for renewal warnings and dump.
func isoDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}

func relativeAge(_ date: Date?, now: Date) -> String {
    guard let date else { return "never" }
    let seconds = now.timeIntervalSince(date)
    if seconds < 0 { return "just now" }
    if seconds < 60 { return "just now" }
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes) min ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours) h ago" }
    return "\(hours / 24) d ago"
}

func updatedText(_ date: Date?, now: Date) -> String {
    "updated \(relativeAge(date, now: now))"
}

/// Freshness budget for a usage row (SPEC §17): the time until the tightest
/// window resets, so a value is flagged stale exactly when its window has
/// rolled (its percentage is then certainly obsolete). Falls back to `backstop`
/// when no reset is known, and never exceeds it — a weekly reset may be days
/// off, but the reading can still go stale before then.
func staleBudget(from updated: Date?, resets: [Date?], backstop: TimeInterval = 24 * 60 * 60) -> TimeInterval? {
    guard let updated else { return nil }
    let budgets = resets.compactMap { $0 }.map { $0.timeIntervalSince(updated) }
    guard let tightest = budgets.min() else { return backstop }
    return max(0, min(tightest, backstop))
}

// MARK: - Generic JSON helpers

/// Recursively search a JSON-decoded value for the first value stored under `key`.
func findValue(forKey key: String, in any: Any) -> Any? {
    if let dict = any as? [String: Any] {
        if let direct = dict[key] { return direct }
        for (_, value) in dict {
            if let found = findValue(forKey: key, in: value) { return found }
        }
    } else if let array = any as? [Any] {
        for value in array {
            if let found = findValue(forKey: key, in: value) { return found }
        }
    }
    return nil
}

func doubleValue(_ any: Any?) -> Double? {
    guard let any else { return nil }
    if let n = any as? NSNumber {
        guard CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    if let s = any as? String, let d = Double(s), d.isFinite { return d }
    return nil
}

/// Tolerant boolean: real booleans, 0/1 numbers, and "true"/"yes"/"false" strings.
func boolValue(_ any: Any?) -> Bool? {
    guard let any else { return nil }
    if let b = any as? Bool { return b }
    if let n = any as? NSNumber { return n.boolValue }
    if let s = any as? String {
        switch s.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }
    return nil
}

/// Time value that may be unix seconds, unix milliseconds, or an ISO-8601 string.
func dateValue(_ any: Any?) -> Date? {
    guard let any else { return nil }
    if let n = any as? NSNumber {
        let d = n.doubleValue
        if d > 1_000_000_000_000 { return Date(timeIntervalSince1970: d / 1000.0) }
        if d > 1_000_000_000 { return Date(timeIntervalSince1970: d) }
        return nil
    }
    if let s = any as? String {
        if let d = Double(s) { return dateValue(d as NSNumber) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
    }
    return nil
}

/// Short, single-line snippet of a JSON object or text, for the debug disclosure.
func jsonSnippet(_ any: Any, maxLength: Int = 400) -> String {
    let raw: String
    if let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        raw = s
    } else {
        raw = String(describing: any)
    }
    return truncate(raw, maxLength: maxLength)
}

func truncate(_ s: String, maxLength: Int) -> String {
    let collapsed = s.replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if collapsed.count <= maxLength { return collapsed }
    return String(collapsed.prefix(maxLength)) + "…"
}

// MARK: - Base32 (RFC 4648, lowercase names without padding)

func base32Decode(_ input: String) -> Data? {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    var lookup: [Character: Int] = [:]
    for (i, c) in alphabet.enumerated() { lookup[c] = i }

    var buffer = 0
    var bitsLeft = 0
    var output = Data()

    for rawChar in input.uppercased() {
        if rawChar == "=" { break }
        guard let value = lookup[rawChar] else { return nil }
        buffer = (buffer << 5) | value
        bitsLeft += 5
        if bitsLeft >= 8 {
            bitsLeft -= 8
            output.append(UInt8((buffer >> bitsLeft) & 0xFF))
        }
    }
    return output
}

// MARK: - Directory helpers

func subdirectories(of url: URL) -> [URL] {
    let keys: [URLResourceKey] = [.isDirectoryKey]
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles]
    ) else { return [] }
    return entries.filter { url in
        (try? url.resourceValues(forKeys: Set(keys)))?.isDirectory == true
    }
}

func modificationDate(of url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
}
