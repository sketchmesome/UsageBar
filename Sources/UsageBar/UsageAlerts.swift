import Foundation
import UserNotifications

/// macOS notifications when a usage window runs low or is burning fast.
///
/// Fed once per refresh with the same "% left" values the menu bar shows, so it
/// adds no timers or I/O of its own. Two kinds of alert, each sent once:
/// - a threshold alert when a window falls to 25%, 10% or 0% left (re-armed
///   once the window recovers, i.e. after a reset);
/// - a burn alert when the recent rate of use would empty the window within
///   the hour (at most one per window every 30 minutes).
/// It also tracks pace: how fast each window is going now compared with how
/// fast it usually goes while you're working (learned from these readings and
/// kept in pace.json; for OpenCode, dollars per hour from the local database).
/// Going 2× faster than usual sends a "Slow down" alert (at most hourly per
/// window), and each active row gets a "pace" note.
/// The first evaluation after launch only records state, so restarting the app
/// never replays alerts for windows that were already low.
final class UsageAlerts {
    private struct Window {
        let key: String
        let name: String
        /// The popover row this value comes from, for its timestamp.
        let source: String
        let left: Double?
        /// Percent-left windows, or a money balance (DeepSeek) in its currency.
        var currency: String? = nil

        var isMoney: Bool { currency != nil }
        /// Which allowance a pace refers to ("5h", "week"), shown with it.
        var label: String? {
            if key.hasSuffix("5h") { return "5h" }
            if key.hasSuffix("Week") { return "week" }
            return nil
        }
        func pace(_ text: String) -> String { text }
        /// "4.2%" / "$0.31" for an amount of this window's unit.
        func amount(_ value: Double, decimals: Int = 1) -> String {
            if let currency { return formatMoney(Money(value, currency)) }
            return "\(fmtDecimal(value, decimals))%"
        }
        /// Any rise this big is a reset (percent) or a top-up (money).
        var resetMargin: Double { isMoney ? 0.01 : 5 }
        /// Below this rate per hour the window counts as idle.
        var minimumActiveRate: Double { isMoney ? 0.01 : 1 }
        /// "Slow down" also needs at least this rate per hour.
        var minimumAlertRate: Double { isMoney ? 0.25 : 3 }
        /// Burn alerts need at least this drop.
        var minimumBurnDrop: Double { isMoney ? 0.25 : 5 }
    }

    /// When a source's value was actually observed, and whether it is stale.
    struct Observation {
        var at: Date?
        var stale: Bool
        /// Read from the service (LIVE/EST), not typed in by hand. Only
        /// measured values feed burn rates.
        var measured: Bool
    }

    static let thresholds: [Double] = [25, 10, 0]
    /// A window must climb this far back above a threshold to re-arm it.
    private static let rearmMargin: Double = 5
    private static let baseHistorySpan: TimeInterval = 45 * 60
    private static let minimumBurnSpan: TimeInterval = 10 * 60
    private static let burnHorizonMinutes: Double = 60
    private static let burnCooldown: TimeInterval = 30 * 60

    private static let basePaceSpan: TimeInterval = 30 * 60
    /// A flat run or an observation gap this long counts as a break.
    private static let baseIdleGap: TimeInterval = 15 * 60
    private static let paceAlertsURL = SettingsStore.directory.appendingPathComponent("pace-alerts.json")

    /// Spans scale with the refresh interval, so a slow interval (up to 30 min)
    /// still leaves enough samples to measure a rate.
    private var interval: TimeInterval = 600
    private var historySpan: TimeInterval { max(Self.baseHistorySpan, 3.5 * interval) }
    private var paceSpan: TimeInterval { max(Self.basePaceSpan, 2.5 * interval) }
    private var idleGap: TimeInterval { max(Self.baseIdleGap, 1.5 * interval) }
    private static let paceFeedGap: TimeInterval = 15 * 60
    private static let paceMinimumSamples = 4
    private static let paceAlertRatio: Double = 2
    private static let paceMinimumDollarsPerHour: Double = 0.25
    private static let paceCooldown: TimeInterval = 60 * 60
    private static let paceURL = SettingsStore.directory.appendingPathComponent("pace.json")

    /// Learned "usual" % per hour while active, per window. Holds rates only.
    private struct Baseline: Codable {
        var usual: Double
        var count: Int
        var fed: Date
    }
    private var baselines: [String: Baseline] = UsageAlerts.loadBaselines()
    /// Persisted, so restarting the app can't repeat an alert within the hour.
    private var lastPaceAlert: [String: Date] = UsageAlerts.loadPaceAlerts()
    /// Newest observation already used to train each baseline, so a reused
    /// reading never trains it twice.
    private var lastTrained: [String: Date] = [:]

    private var seeded = false
    private var notified: [String: Set<Double>] = [:]
    /// Recent readings per window. Saved to pace-history.json after each
    /// refresh that added one, so pace survives app restarts and updates.
    private var history: [String: [(at: Date, left: Double)]] = UsageAlerts.loadHistory()
    private var historyChanged = false
    private static let historyURL = SettingsStore.directory.appendingPathComponent("pace-history.json")
    private var lastBurnAlert: [String: Date] = [:]

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// - Parameter observations: per popover row id ("claude", "codex", …),
    ///   when its value was read. Burn rates use these times, so a reading that
    ///   is merely reused is never mistaken for new consumption.
    /// - Returns: a short pace note per popover row id (e.g. "5h pace 4.2%/h · usual 3.2%/h (1.3×)")
    ///   for rows that are actively being used.
    @discardableResult
    func evaluate(values: MenuBarValues, observations: [String: Observation], opencodePace: OpenCodePace? = nil,
                  interval: TimeInterval = 600, now: Date, enabled: Bool) -> [String: String] {
        self.interval = interval
        repairClock(now: now)
        let windows = [
            Window(key: "claude5h", name: "Claude 5h", source: "claude", left: values.claude5hLeft),
            Window(key: "claudeWeek", name: "Claude week", source: "claude", left: values.claudeWeekLeft),
            Window(key: "codex5h", name: "Codex 5h", source: "codex", left: values.codex5hLeft),
            Window(key: "codexWeek", name: "Codex week", source: "codex", left: values.codexWeekLeft),
            Window(key: "opencode5h", name: "OpenCode 5h", source: "opencode", left: values.opencode5hLeft),
            Window(key: "opencodeWeek", name: "OpenCode week", source: "opencode", left: values.opencodeWeekLeft),
            Window(key: "grok", name: "Grok Bot", source: "grok", left: values.grokPercentLeft),
            // A prepaid balance: its pace is dollars per hour spent.
            // Keyed by currency, so a change of currency starts a fresh history.
            Window(key: "deepseek-\(values.deepseekOriginalBalance?.currency ?? "")", name: "DeepSeek API", source: "deepseek",
                   left: values.deepseekOriginalBalance?.amount,
                   currency: values.deepseekOriginalBalance?.currency)
        ]
        let announce = enabled && seeded
        var notes: [String: (ratio: Double, text: String)] = [:]
        for window in windows {
            guard let left = window.left else { continue }
            let observation = observations[window.source]
            if !window.isMoney { checkThresholds(window, left: left, announce: announce) }
            if let observation, observation.measured, !observation.stale {
                checkBurn(window, left: left, at: observation.at ?? now, now: now, announce: announce)
                // Every window is measured (and can alert); the row shows its
                // 5h window's rate, or its only window's.
                if let pace = checkPace(window, left: left, now: now, announce: announce),
                   notes[window.source] == nil || window.label == "5h" {
                    notes[window.source] = pace
                }
            }
        }
        // OpenCode's dollar pace only drives its "Slow down" alert; the row
        // shows %/h like the others.
        if let opencodePace { _ = checkOpenCodePace(opencodePace, now: now, announce: announce) }
        seeded = true
        if historyChanged {
            historyChanged = false
            saveHistory()
        }
        return notes.mapValues(\.text)
    }

    /// After the clock is set back, samples and timestamps from the "future"
    /// would freeze pace and block learning/alerts until wall time caught up.
    /// Drop such history and pull other dates back to now.
    private func repairClock(now: Date) {
        let limit = now.addingTimeInterval(60)
        guard history.values.contains(where: { $0.contains { $0.at > limit } })
            || lastTrained.values.contains(where: { $0 > limit })
            || lastBurnAlert.values.contains(where: { $0 > limit })
            || lastPaceAlert.values.contains(where: { $0 > limit })
            || baselines.values.contains(where: { $0.fed > limit }) else { return }
        history = history.mapValues { $0.filter { $0.at <= limit } }
        historyChanged = true
        lastTrained = lastTrained.filter { $0.value <= limit }
        lastBurnAlert = lastBurnAlert.filter { $0.value <= limit }
        lastPaceAlert = lastPaceAlert.mapValues { min($0, now) }
        baselines = baselines.mapValues { var b = $0; b.fed = min(b.fed, now); return b }
        saveBaselines()
        savePaceAlerts()
    }

    // MARK: - Pace

    /// Rate over the last 30 minutes vs the learned usual rate for this window.
    private func checkPace(_ window: Window, left: Double, now: Date,
                           announce: Bool) -> (ratio: Double, text: String)? {
        let observed = (history[window.key] ?? []).filter { now.timeIntervalSince($0.at) <= paceSpan }
        let recent = Self.activeStretch(observed, idleGap: idleGap)
        // Grok Bot only writes a reading when the bot uses Grok, so no recent
        // reading means it's idle. Elsewhere an old reading means the source
        // couldn't be read (e.g. Claude asked us to wait), so say nothing.
        guard let first = recent.first, let last = recent.last else {
            return window.source == "grok" ? idleNote(window) : nil
        }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= Self.minimumBurnSpan else {
            // In use, or just started watching: not 10 minutes of readings yet.
            // Too few readings yet is "measuring"; a stretch trimmed to its
            // last sample by a long flat run is confirmed idle.
            return first.left > last.left || observed.count < 2 ? (-0.5, "measuring…") : idleNote(window)
        }
        let perHour = (first.left - last.left) / (span / 3600)
        if perHour <= 0 { return idleNote(window) }
        let rate = "\(window.amount(perHour, decimals: window.isMoney ? 2 : 1))/h"
        // Slow but real use: shown as is, not compared or learned from.
        guard perHour >= window.minimumActiveRate else { return (-0.5, window.pace(rate)) }

        // Compare against what was usual *before* this burst, then learn — but
        // only while still in use (a drop in the last 10 min), so the tail of a
        // session winding down can't teach a slower "usual".
        let previous = baselines[window.key]
        if let lastDrop = Self.lastDrop(recent), now.timeIntervalSince(lastDrop) <= Self.minimumBurnSpan {
            train(window.key, perHour: perHour, observedAt: last.at, now: now)
        }
        guard let previous, previous.usual > 0, previous.count >= Self.paceMinimumSamples else {
            return (0, window.pace(rate))
        }
        let usual = previous.usual
        let ratio = perHour / usual
        if announce, ratio >= Self.paceAlertRatio, perHour >= window.minimumAlertRate,
           lastPaceAlert[window.key].map({ now.timeIntervalSince($0) >= Self.paceCooldown }) ?? true {
            lastPaceAlert[window.key] = now
            savePaceAlerts()
            let hoursLeft = left / perHour
            post(
                id: "\(window.key)-pace",
                title: "Slow down",
                body: "\(window.name) is going \(fmtDecimal(ratio, 1))× faster than usual (\(rate) vs \(window.amount(usual))/h). At this pace it's empty in ~\(Self.duration(hours: hoursLeft))."
            )
        }
        return (ratio, window.pace(rate))
    }

    /// Not in use right now.
    private func idleNote(_ window: Window) -> (ratio: Double, text: String) {
        (-1, window.pace("\(window.amount(0, decimals: 0))/h"))
    }

    /// The latest stretch of continuous use in `samples`: it starts after the
    /// last break — a run with no decline lasting `idleGap` or more (its last
    /// flat sample is kept as the moment use resumed), or a gap between
    /// observations that long (sleep, app restart). Rates are then measured
    /// over time actually spent working, so a break — at the start or in the
    /// middle — doesn't make the pace look slower than it is.
    static func activeStretch(_ samples: [(at: Date, left: Double)], idleGap: TimeInterval) -> [(at: Date, left: Double)] {
        guard samples.count >= 2 else { return samples }
        var start = 0
        var flatFrom: Int?
        for k in 1..<samples.count {
            if samples[k].at.timeIntervalSince(samples[k - 1].at) >= idleGap {
                start = k
                flatFrom = nil
                continue
            }
            if samples[k].left < samples[k - 1].left {
                flatFrom = nil
            } else {
                let runStart = flatFrom ?? (k - 1)
                flatFrom = runStart
                if samples[k].at.timeIntervalSince(samples[runStart].at) >= idleGap { start = k }
            }
        }
        return Array(samples[start...])
    }

    /// When the value last went down.
    static func lastDrop(_ samples: [(at: Date, left: Double)]) -> Date? {
        guard samples.count >= 2 else { return nil }
        for i in stride(from: samples.count - 1, through: 1, by: -1) where samples[i].left < samples[i - 1].left {
            return samples[i].at
        }
        return nil
    }

    /// Learn at most every 15 min and only from a new observation; a burst
    /// counts at most double, so one heavy session can't redefine "usual".
    private func train(_ key: String, perHour: Double, observedAt: Date, now: Date) {
        if let trained = lastTrained[key], observedAt <= trained { return }
        if let b = baselines[key], now.timeIntervalSince(b.fed) < Self.paceFeedGap { return }
        lastTrained[key] = observedAt
        if var b = baselines[key] {
            b.usual = 0.85 * b.usual + 0.15 * min(perHour, 2 * b.usual)
            b.count += 1
            b.fed = now
            baselines[key] = b
        } else {
            baselines[key] = Baseline(usual: perHour, count: 1, fed: now)
        }
        saveBaselines()
    }

    /// OpenCode spend in $/h over the last 30 min vs your usual active hour.
    private func checkOpenCodePace(_ pace: OpenCodePace, now: Date, announce: Bool) -> String? {
        guard pace.recentPerHour >= 0.01 else {
            guard let usual = pace.usualPerHour, usual > 0 else { return "pace $0/h" }
            return "pace $0/h · usual $\(fmtDecimal(usual, 2))/h"
        }
        let rate = "$\(fmtDecimal(pace.recentPerHour, 2))/h"
        guard let usual = pace.usualPerHour, usual > 0 else { return "pace \(rate)" }
        let ratio = pace.recentPerHour / usual
        if announce, ratio >= Self.paceAlertRatio, pace.recentPerHour >= Self.paceMinimumDollarsPerHour,
           lastPaceAlert["opencode$"].map({ now.timeIntervalSince($0) >= Self.paceCooldown }) ?? true {
            lastPaceAlert["opencode$"] = now
            savePaceAlerts()
            post(
                id: "opencode-pace",
                title: "Slow down",
                body: "OpenCode is spending \(rate), \(fmtDecimal(ratio, 1))× your usual $\(fmtDecimal(usual, 2))/h. Check which model you're on."
            )
        }
        return "pace \(rate) · usual $\(fmtDecimal(usual, 2))/h (\(fmtDecimal(ratio, 1))×)"
    }

    private static func duration(hours: Double) -> String {
        let minutes = max(1, Int((hours * 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 48 * 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes / 1440)d"
    }

    /// Dates from a clock that was later set back are pulled back to now, so
    /// they can't block learning or alerts until wall time catches up.
    private static func loadBaselines() -> [String: Baseline] {
        guard let data = try? Data(contentsOf: paceURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let now = Date()
        return ((try? decoder.decode([String: Baseline].self, from: data)) ?? [:]).mapValues {
            var b = $0
            b.fed = min(b.fed, now)
            return b
        }
    }

    /// Readings older than an hour are useless for pace, so only those are kept.
    private static func loadHistory() -> [String: [(at: Date, left: Double)]] {
        guard let data = try? Data(contentsOf: historyURL),
              let raw = try? JSONDecoder().decode([String: [[Double]]].self, from: data) else { return [:] }
        let now = Date().timeIntervalSince1970
        return raw.mapValues { pairs in
            pairs.compactMap { pair -> (at: Date, left: Double)? in
                guard pair.count == 2, pair[0] <= now + 60, now - pair[0] <= 3600 else { return nil }
                return (Date(timeIntervalSince1970: pair[0]), pair[1])
            }
        }.filter { !$0.value.isEmpty }
    }

    private func saveHistory() {
        let raw = history.mapValues { $0.map { [$0.at.timeIntervalSince1970, $0.left] } }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? FileManager.default.createDirectory(at: SettingsStore.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.historyURL, options: .atomic)
    }

    private static func loadPaceAlerts() -> [String: Date] {
        guard let data = try? Data(contentsOf: paceAlertsURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let now = Date()
        return ((try? decoder.decode([String: Date].self, from: data)) ?? [:]).mapValues { min($0, now) }
    }

    private func savePaceAlerts() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(lastPaceAlert) else { return }
        try? FileManager.default.createDirectory(at: SettingsStore.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.paceAlertsURL, options: .atomic)
    }

    private func saveBaselines() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(baselines) else { return }
        try? FileManager.default.createDirectory(at: SettingsStore.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.paceURL, options: .atomic)
    }

    private func checkThresholds(_ window: Window, left: Double, announce: Bool) {
        var sent = notified[window.key] ?? []
        sent = sent.filter { left <= $0 + Self.rearmMargin }
        let crossed = Self.thresholds.filter { left <= $0 && !sent.contains($0) }
        if let lowest = crossed.min() {
            // Mark every threshold at or above the lowest crossed one, so a drop
            // straight from 30% to 8% sends one alert, not two.
            sent.formUnion(Self.thresholds.filter { $0 >= lowest })
            if announce {
                let body = lowest == 0
                    ? "\(window.name) is used up."
                    : "\(window.name): \(Int(left.rounded()))% left."
                post(id: "\(window.key)-\(Int(lowest))", title: "Usage low", body: body)
            }
        }
        notified[window.key] = sent
    }

    private func checkBurn(_ window: Window, left: Double, at observedAt: Date, now: Date, announce: Bool) {
        var samples = history[window.key] ?? []
        // The same observation seen again (a cached or reused reading) adds nothing.
        if let last = samples.last, observedAt <= last.at { return }
        // A jump back up is a window reset; earlier samples no longer apply.
        if let last = samples.last, left > last.left + window.resetMargin { samples.removeAll() }
        samples.append((observedAt, left))
        historyChanged = true
        samples.removeAll { now.timeIntervalSince($0.at) > historySpan }
        history[window.key] = samples

        guard announce, left > 0, let oldest = Self.activeStretch(samples, idleGap: idleGap).first else { return }
        let span = observedAt.timeIntervalSince(oldest.at)
        let drop = oldest.left - left
        guard span >= Self.minimumBurnSpan, drop >= window.minimumBurnDrop else { return }
        let perMinute = drop / (span / 60)
        let minutesToEmpty = left / perMinute
        guard minutesToEmpty <= Self.burnHorizonMinutes else { return }
        if let last = lastBurnAlert[window.key], now.timeIntervalSince(last) < Self.burnCooldown { return }
        lastBurnAlert[window.key] = now
        post(
            id: "\(window.key)-burn",
            title: "Burning fast",
            body: "\(window.name): down \(window.amount(drop, decimals: 0)) in \(Int((span / 60).rounded())) min — at this pace it's empty in ~\(max(1, Int(minutesToEmpty.rounded()))) min."
        )
    }

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "\(id)-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
