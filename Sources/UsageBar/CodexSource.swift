import Foundation

struct CodexReading {
    var fiveHourLeft: Int?
    var weekLeft: Int?
    /// Plan name derived from `rate_limits.plan_type`, e.g. "ChatGPT Plus"
    /// (SPEC §13 continued).
    var planName: String?
    var row: UsageRow
}

/// Row 1 — Codex.
///
/// Checks up to 20 recent `rollout-*.jsonl` files, newest first, reading only
/// the last 256 KB of each, and uses the newest file with rate limits.
final class CodexSource: UsageSource {
    let id = "codex"

    private let sessionsRoot = usageBarHome.appendingPathComponent(".codex/sessions", isDirectory: true)

    func reading(now: Date, force: Bool = false) -> CodexReading {
        // The app server knows the account's limits from any surface — the Codex
        // desktop app writes no local rollout — so prefer it, and keep the
        // rollout as the offline fallback.
        if let live = appServerReading(now: now, force: force) { return live }
        return rolloutReading(now: now)
    }

    /// Live limits from the local `codex app-server` (SPEC §18).
    private func appServerReading(now: Date, force: Bool) -> CodexReading? {
        guard let snapshot = CodexAppServer.fetch(now: now, force: force) else { return nil }

        let fiveLeft = snapshot.primary.map { max(0, min(100, 100 - $0.usedPercent)) }
        let weekLeft = snapshot.secondary.map { max(0, min(100, 100 - $0.usedPercent)) }

        var pieces: [String] = []
        var footnotes: [String] = []
        if let fiveLeft {
            let reset = snapshot.primary?.resetsAt.map { " (resets \(clockTime($0)))" } ?? ""
            pieces.append("5h: \(Int(fiveLeft.rounded()))% left\(reset)")
        }
        if let weekLeft {
            let reset = snapshot.secondary?.resetsAt.map { " (resets \(weekdayTime($0)))" } ?? ""
            footnotes.append("Week: \(Int(weekLeft.rounded()))% left\(reset)")
        }

        let planName = Self.planName(from: snapshot.planType)
        let footnoteParts = ([planName] + footnotes).compactMap { $0 }

        return CodexReading(
            fiveHourLeft: fiveLeft.map { Int($0.rounded()) },
            weekLeft: weekLeft.map { Int($0.rounded()) },
            planName: planName,
            row: UsageRow(
                id: id,
                title: "Codex",
                value: pieces.isEmpty ? "no rate limits" : pieces.joined(separator: " · "),
                footnote: footnoteParts.isEmpty ? "codex app-server" : footnoteParts.joined(separator: " · "),
                tag: .live,
                updated: snapshot.fetchedAt,
                debug: "codex app-server: account/rateLimits/read",
                staleAfter: staleBudget(
                    from: snapshot.fetchedAt,
                    resets: [snapshot.primary?.resetsAt, snapshot.secondary?.resetsAt]
                )
            )
        )
    }

    private func rolloutReading(now: Date) -> CodexReading {
        let files = recentRolloutFiles()
        guard let newestFile = files.first else {
            return CodexReading(
                fiveHourLeft: nil,
                weekLeft: nil,
                planName: nil,
                row: UsageRow(
                    id: id,
                    title: "Codex",
                    value: "no session data",
                    footnote: "~/.codex/sessions not found",
                    tag: .none,
                    updated: nil
                )
            )
        }

        var selected: (file: URL, limits: [String: Any])?
        for file in files {
            guard let data = tail(of: file, byteCount: 256 * 1024),
                  let limits = lastRateLimits(in: data) else { continue }
            // After a usage limit is hit the newest rollouts can carry a
            // rate_limits object with `primary`/`secondary` null (or missing
            // their used_percent). Those are not usable, so keep scanning
            // older files rather than stopping on the first non-empty object.
            let primaryUsed = doubleValue((limits["primary"] as? [String: Any])?["used_percent"])
            let secondaryUsed = doubleValue((limits["secondary"] as? [String: Any])?["used_percent"])
            guard primaryUsed != nil || secondaryUsed != nil else { continue }
            selected = (file, limits)
            break
        }
        guard let selected else {
            return CodexReading(
                fiveHourLeft: nil,
                weekLeft: nil,
                planName: nil,
                row: UsageRow(
                    id: id,
                    title: "Codex",
                    value: "no rate_limits found",
                    footnote: newestFile.lastPathComponent,
                    tag: .none,
                    updated: modificationDate(of: newestFile) ?? now
                )
            )
        }
        let file = selected.file
        let limits = selected.limits
        let mtime = modificationDate(of: file) ?? now

        let primary = limits["primary"] as? [String: Any]
        let secondary = limits["secondary"] as? [String: Any]

        let primaryUsed = doubleValue(primary?["used_percent"])
        let secondaryUsed = doubleValue(secondary?["used_percent"])

        let fiveHourLeft = primaryUsed.flatMap { $0.isFinite ? leftPercent($0) : nil }
        let weekLeft = secondaryUsed.flatMap { $0.isFinite ? leftPercent($0) : nil }
        let primaryReset = dateValue(primary?["resets_at"])
        let secondaryReset = dateValue(secondary?["resets_at"])

        var pieces: [String] = []
        var footnotes: [String] = []

        if let fiveHourLeft, let reset = primaryReset {
            pieces.append("5h: \(fiveHourLeft)% left (resets \(clockTime(reset)))")
        } else if let fiveHourLeft {
            pieces.append("5h: \(fiveHourLeft)% left")
        }

        if let weekLeft, let reset = secondaryReset {
            footnotes.append("Week: \(weekLeft)% left (resets \(weekdayTime(reset)))")
        } else if let weekLeft {
            footnotes.append("Week: \(weekLeft)% left")
        }

        let planName = Self.planName(from: findValue(forKey: "plan_type", in: limits) as? String)

        let value = pieces.isEmpty ? "rate_limits unreadable" : pieces.joined(separator: " · ")
        let footnoteParts = ([planName] + (footnotes.isEmpty ? [] : footnotes)).compactMap { $0 }
        let footnote = footnoteParts.isEmpty ? file.lastPathComponent : footnoteParts.joined(separator: " · ")

        return CodexReading(
            fiveHourLeft: fiveHourLeft,
            weekLeft: weekLeft,
            planName: planName,
            row: UsageRow(
                id: id,
                title: "Codex",
                value: value,
                footnote: footnote,
                tag: .live,
                updated: mtime,
                debug: jsonSnippet(limits),
                // Stale once the 5h window has rolled (SPEC §17).
                staleAfter: staleBudget(from: mtime, resets: [primaryReset, secondaryReset])
            )
        )
    }

    /// Percent left, clamped to 0...100. A fully used window (`used_percent`
    /// of 100) reads as "0% left".
    private func leftPercent(_ used: Double) -> Int {
        Int(max(0, min(100, 100 - used)).rounded())
    }

    /// Maps `rate_limits.plan_type` (e.g. "plus") to a "ChatGPT Plus" label.
    static func planName(from raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let key = raw.lowercased()
            .replacingOccurrences(of: "chatgpt_", with: "")
            .replacingOccurrences(of: "chatgpt ", with: "")
        switch key {
        case "plus": return "ChatGPT Plus"
        case "pro": return "ChatGPT Pro"
        case "team": return "ChatGPT Team"
        case "business": return "ChatGPT Business"
        case "enterprise": return "ChatGPT Enterprise"
        case "free": return "ChatGPT Free"
        default: return "ChatGPT \(raw.capitalized)"
        }
    }

    func makeRow(settings: Settings, now: Date) -> UsageRow {
        reading(now: now).row
    }

    // MARK: - File discovery

    private func recentRolloutFiles() -> [URL] {
        // Walk only the newest year/month/day directories, by name descending,
        // checking at most 3 day-directories.
        let years = subdirectories(of: sessionsRoot).sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard !years.isEmpty else { return [] }

        var dayDirs: [URL] = []
        outer: for year in years {
            let months = subdirectories(of: year).sorted { $0.lastPathComponent > $1.lastPathComponent }
            for month in months {
                let days = subdirectories(of: month).sorted { $0.lastPathComponent > $1.lastPathComponent }
                for day in days {
                    dayDirs.append(day)
                    if dayDirs.count >= 3 { break outer }
                }
            }
        }

        var candidates: [(url: URL, date: Date)] = []
        for dir in dayDirs {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for file in files where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
                let date = modificationDate(of: file) ?? .distantPast
                candidates.append((file, date))
            }
        }
        return candidates.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.url.lastPathComponent > $1.url.lastPathComponent
        }.prefix(20).map { $0.url }
    }

    private func tail(of url: URL, byteCount: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let readSize = min(UInt64(byteCount), end)
        guard readSize > 0 else { return Data() }
        do {
            try handle.seek(toOffset: end - readSize)
        } catch {
            return nil
        }
        return try? handle.read(upToCount: Int(readSize))
    }

    private func lastRateLimits(in data: Data) -> [String: Any]? {
        let text = String(decoding: data, as: UTF8.self)
        for rawLine in text.split(separator: "\n").reversed() {
            guard rawLine.contains("\"rate_limits\""),
                  let json = try? JSONSerialization.jsonObject(with: Data(rawLine.utf8)),
                  let limits = findValue(forKey: "rate_limits", in: json) as? [String: Any],
                  !limits.isEmpty else { continue }
            let primary = doubleValue((limits["primary"] as? [String: Any])?["used_percent"])
            let secondary = doubleValue((limits["secondary"] as? [String: Any])?["used_percent"])
            guard primary?.isFinite == true || secondary?.isFinite == true else { continue }
            return limits
        }
        return nil
    }
}
