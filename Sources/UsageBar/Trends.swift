import Foundation
import UserNotifications

/// Slow trends that need days of history: how long the DeepSeek balance lasts
/// at your usual spend, and when the VPS disk fills at its current growth.
///
/// Keeps one sample per hour per series (values only — a balance and a disk
/// size, nothing else) for 30 days in trends.json, plus when each warning was
/// last sent. Every refresh is still looked at: drops seen between saved
/// samples are added to the next one, and a disk cleanup seen in between marks
/// it, so a top-up or cleanup inside the hour isn't lost. Fed once per refresh;
/// adds no timers.
final class Trends {
    private struct Sample: Codable {
        var t: Double
        var v: Double
        /// Total of every drop observed since the previous sample.
        var d: Double?
        /// A cleanup (big disk drop) was observed since the previous sample.
        var c: Bool?
    }

    private struct Stored: Codable {
        var series: [String: [Sample]] = [:]
        var alerted: [String: Double] = [:]
        /// Currency each money series is in; a change starts it over.
        var currency: [String: String]? = [:]
        /// Drops/cleanups seen since each series' last saved sample, kept so a
        /// restart within the hour doesn't lose them.
        var pending: [String: Pending]? = [:]
    }

    /// What has been observed since the last saved sample.
    private struct Pending: Codable {
        var last: Double
        /// When `last` was measured (the VPS reports a cached reading's time).
        var at: Double?
        var drops: Double = 0
        var cleanup = false
    }

    private static let url = SettingsStore.directory.appendingPathComponent("trends.json")
    private static let spacing: TimeInterval = 3600
    private static let keep: TimeInterval = 30 * 86_400
    private static let lookback: TimeInterval = 7 * 86_400
    /// Need this much history before estimating a daily rate.
    private static let minimumSpan: TimeInterval = 20 * 3600
    private static let alertCooldown: TimeInterval = 86_400
    static let runwayWarningDays: Double = 3
    static let diskWarningDays: Double = 14
    /// A disk drop bigger than this is a cleanup; growth is measured after it.
    private static let cleanupGB: Double = 0.5
    /// A disk reading older than this is too old to project from.
    private static let diskMaxAge: TimeInterval = 2 * 3600

    private var stored = Trends.load()
    private lazy var pending: [String: Pending] = stored.pending ?? [:]

    struct Notes {
        var deepseek: String?
        var disk: String?
    }

    /// - Parameters:
    ///   - balance: live DeepSeek balance, nil when not live.
    ///   - disk: live VPS disk (used, free) in GB and when it was measured,
    ///     nil when unknown.
    func update(balance: Money?, disk: (used: Double, free: Double?, at: Date)?, now: Date, enabled: Bool) -> Notes {
        var changed = prune(now: now)
        var notes = Notes()
        if let balance {
            if stored.currency?["deepseek"] != balance.currency {
                stored.series["deepseek"] = nil
                pending["deepseek"] = nil
                stored.pending = pending
                stored.currency = (stored.currency ?? [:]).merging(["deepseek": balance.currency]) { $1 }
                changed = true
            }
            changed = record("deepseek", balance.amount, now: now) || changed
            if let daily = dailySpend(now: now), daily >= 0.005 {
                let days = balance.amount / daily
                let perDay = formatMoney(Money(daily, balance.currency))
                notes.deepseek = "\(perDay)/day · ~\(Self.days(days)) left"
                if days < Self.runwayWarningDays {
                    changed = warn("deepseek", now: now, enabled: enabled, title: "DeepSeek balance low",
                                   body: "\(formatMoney(balance)) lasts about \(Self.days(days)) at your usual \(perDay)/day. Time to top up.") || changed
                }
            }
        }
        // An old cached reading is neither recorded nor projected from, so a
        // frozen value never reads as "steady".
        if let disk, now.timeIntervalSince(disk.at) <= Self.diskMaxAge {
            changed = record("vpsDisk", disk.used, now: min(disk.at, now)) || changed
            if let growth = diskGrowth(now: now) {
                if growth < 0.02 {
                    notes.disk = "steady"
                } else if let free = disk.free {
                    let days = free / growth
                    notes.disk = "+\(fmtDecimal(growth, 2)) GB/day · fills in ~\(Self.days(days))"
                    if days < Self.diskWarningDays {
                        changed = warn("vpsDisk", now: now, enabled: enabled, title: "VPS disk filling up",
                                       body: "At +\(fmtDecimal(growth, 2)) GB/day the disk is full in about \(Self.days(days)) (\(fmtDecimal(free, 1)) GB free).") || changed
                    }
                } else {
                    notes.disk = "+\(fmtDecimal(growth, 2)) GB/day"
                }
            }
        }
        if changed { save() }
        return notes
    }

    // MARK: - Estimates

    /// Average spend per day over the last week: every drop observed (top-ups,
    /// which raise the balance, are skipped) over the time covered. Nil until
    /// there's most of a day of history.
    private func dailySpend(now: Date) -> Double? {
        let points = window("deepseek", now: now)
        guard let first = points.first, let current = pending["deepseek"] else { return nil }
        let span = now.timeIntervalSince1970 - first.t
        guard span >= Self.minimumSpan else { return nil }
        var spent = current.drops
        for i in points.indices.dropFirst() {
            spent += points[i].d ?? max(0, points[i - 1].v - points[i].v)
        }
        return spent / (span / 86_400)
    }

    /// GB per day since the last cleanup, over at most the last week.
    private func diskGrowth(now: Date) -> Double? {
        guard let current = pending["vpsDisk"], !current.cleanup else { return nil }
        var points = window("vpsDisk", now: now)
        if let cut = points.indices.last(where: { points[$0].c == true }) {
            points = Array(points[cut...])
        }
        guard let first = points.first else { return nil }
        // Measured up to the latest reading, not to now.
        let span = (current.at ?? now.timeIntervalSince1970) - first.t
        guard span >= Self.minimumSpan else { return nil }
        return max(0, (current.last - first.v) / (span / 86_400))
    }

    /// The last week's saved samples.
    private func window(_ key: String, now: Date) -> [Sample] {
        let nowT = now.timeIntervalSince1970
        return (stored.series[key] ?? []).filter { nowT - $0.t <= Self.lookback && $0.t <= nowT }
    }

    // MARK: - Storage and alerts

    /// Notes what changed since the last observation, and saves a sample once
    /// an hour. `now` is when the value was measured. Returns true when the
    /// stored state changed.
    private func record(_ key: String, _ value: Double, now: Date) -> Bool {
        let nowT = now.timeIntervalSince1970
        var series = stored.series[key] ?? []
        // A repeated or older reading (a cached VPS value) adds nothing.
        if let seen = pending[key]?.at, nowT <= seen { return false }
        if let last = series.last, nowT < last.t { return false }
        var state = pending[key] ?? Pending(last: series.last?.v ?? value)
        let delta = state.last - value
        if delta > 0 { state.drops += delta }
        if key == "vpsDisk", delta > Self.cleanupGB { state.cleanup = true }
        state.last = value
        state.at = nowT

        if let last = series.last, nowT - last.t < Self.spacing {
            // Persist whenever the value moved: a drop is spend, and a rise (a
            // top-up, disk growth) is the new baseline a restart must keep.
            let moved = delta != 0
            pending[key] = state
            if moved { stored.pending = pending }
            return moved
        }
        series.append(Sample(t: nowT, v: value,
                             d: series.isEmpty ? nil : state.drops,
                             c: state.cleanup ? true : nil))
        stored.series[key] = series
        pending[key] = Pending(last: value, at: nowT)
        stored.pending = pending
        return true
    }

    /// Drops samples older than 30 days or dated in the future (the clock was
    /// set back), for every series — including ones no longer reported.
    private func prune(now: Date) -> Bool {
        let nowT = now.timeIntervalSince1970
        var changed = false
        for (key, series) in stored.series {
            let kept = series.filter { $0.t <= nowT + 60 && nowT - $0.t <= Self.keep }
            if kept.count != series.count {
                stored.series[key] = kept.isEmpty ? nil : kept
                changed = true
            }
        }
        for (key, state) in pending where (state.at ?? 0) > nowT + 60 {
            pending[key] = nil
            stored.pending = pending
            changed = true
        }
        for (key, at) in stored.alerted where at > nowT + 60 {
            stored.alerted[key] = nil
            changed = true
        }
        return changed
    }

    /// Sends a warning at most once a day. Nothing is recorded while alerts are
    /// off, so turning them back on doesn't start with a used-up cooldown.
    private func warn(_ key: String, now: Date, enabled: Bool, title: String, body: String) -> Bool {
        guard enabled else { return false }
        let nowT = now.timeIntervalSince1970
        if let last = stored.alerted[key], nowT - last < Self.alertCooldown { return false }
        stored.alerted[key] = nowT
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "\(key)-\(UUID().uuidString)", content: content, trigger: nil)
        )
        return true
    }

    static func days(_ value: Double) -> String {
        if value < 1 { return "\(max(1, Int((value * 24).rounded()))) h" }
        if value >= 365 { return "over a year" }
        let rounded = Int(value.rounded())
        return rounded == 1 ? "1 day" : "\(rounded) days"
    }

    private static func load() -> Stored {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return Stored() }
        return stored
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: SettingsStore.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}

/// Daily burn of a weekly window: what's used so far this week over the days
/// since it started, and how long what's left lasts at that rate. Computed
/// from the reading alone, so it needs no history and costs nothing.
enum WeeklyBurn {
    static let length: TimeInterval = 7 * 86_400
    /// Too early in the week for a daily rate to mean much.
    private static let minimumElapsed: TimeInterval = 6 * 3600

    static func note(left: Double?, reset: Date?, now: Date) -> String? {
        guard let left, let reset, reset > now else { return nil }
        let elapsed = now.timeIntervalSince(reset.addingTimeInterval(-length))
        guard elapsed >= minimumElapsed, elapsed <= length else { return nil }
        let perDay = (100 - left) / (elapsed / 86_400)
        guard perDay >= 0.5 else { return "0%/day" }
        let rate = "\(fmtDecimal(perDay, perDay < 10 ? 1 : 0))%/day"
        let daysLeft = left / perDay
        let toReset = reset.timeIntervalSince(now) / 86_400
        if left <= 0 { return "\(rate) · used up until reset" }
        if daysLeft >= toReset { return "\(rate) · lasts until reset" }
        return "\(rate) · runs out in ~\(Trends.days(daysLeft)), before reset"
    }
}
