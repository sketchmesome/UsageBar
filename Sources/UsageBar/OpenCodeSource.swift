import Foundation
import WebKit

/// OpenCode's numeric windows plus the finished row (SPEC §12).
struct OpenCodeReading {
    var fiveHourLeft: Double?
    var weekLeft: Double?
    /// Live plan name and price/caps discovered on the page (SPEC §13 continued).
    var planName: String?
    var monthlyPriceUSD: Double?
    var capFiveHourUSD: Double?
    var capWeekUSD: Double?
    var capMonthUSD: Double?
    /// When each window resets, from the console's "Resets in …" text.
    var fiveHourReset: Date?
    var weekReset: Date?
    var monthReset: Date?
    /// True when this reading came from a previous load because the fresh one
    /// failed or carried nothing usable. Surfaced so the UI never presents a
    /// reused reading as current (SPEC §17).
    var reused: Bool = false
    var row: UsageRow
}

/// Row 3 — OpenCode Go.
///
/// Primary source is an offscreen scrape of the console page; when that yields
/// nothing usable we estimate from the local OpenCode sqlite database.
final class OpenCodeSource: UsageSource {
    let id = "opencode"

    /// Strong references so the scraper (and its webview) stay alive until the
    /// scrape finishes. Touched on the main thread only.
    private var activeScrapers: [UUID: OffscreenScraper] = [:]

    /// Last successful console load, whether or not it parsed. Gates the reload
    /// interval (SPEC §10) so a page that keeps returning nothing usable does
    /// not spin up a webview on every tick.
    private let cacheLock = NSLock()
    private var cached: (payload: ScrapePayload, at: Date, url: String)?

    /// Last load that actually carried a reading, reused when a fresh load fails
    /// or returns nothing usable, so a transient failure doesn't drop to the
    /// crude estimate.
    private var lastGood: (payload: ScrapePayload, at: Date, url: String)?

    /// Local-database spend recorded at each console load, so later refreshes
    /// can add what was spent since (see `liveAdjusted`). Guarded by cacheLock.
    private var cachedSpend: OpenCodeSpend?
    private var goodSpend: OpenCodeSpend?

    /// New Go spend since the last console load that triggers an early reload
    /// instead of waiting out the OpenCode interval.
    private static let reloadSpendJumpUSD = 0.5
    /// …but never more often than this.
    private static let minimumReloadGap: TimeInterval = 300

    /// When the last console load failed outright (offline, timeout). Further
    /// automatic loads wait `failureBackoff` so a dead network doesn't spin up
    /// a webview every tick; an explicit Refresh still loads. Guarded by cacheLock.
    private var lastFailure: Date?
    private static let failureBackoff: TimeInterval = 600

    /// Most recent LIVE monthly dollar cap seen on the console page, used when
    /// the estimate fallback needs a cap (SPEC §13 continued).
    private let capLock = NSLock()
    private var liveCapMonthUSD: Double?

    func makeRow(settings: Settings, now: Date) -> UsageRow {
        reading(settings: settings, now: now, forceReload: false, fx: FX.make(settings: settings, rates: nil)).row
    }

    /// Runs one refresh. When `forceReload` is false and the last successful
    /// console load is younger than the OpenCode interval, the cached payload is
    /// reused instead of reloading the webview. An explicit popover "Refresh"
    /// passes `forceReload: true`.
    func reading(settings: Settings, now: Date, forceReload: Bool, fx: FX) -> OpenCodeReading {
        let interval = TimeInterval(settings.clampedOpenCodeRefreshMinutes * 60)
        let urlString = settings.effectiveConsoleURL
        // One database snapshot per refresh, shared by the early-reload check
        // and the live adjustment.
        let cachedLoad = currentCache().flatMap { $0.url == urlString ? $0 : nil }
        let snapshot = cachedLoad.flatMap { OpenCodeDatabase.snapshot(now: now, since: $0.at) }

        if !forceReload, let failed = currentFailure(), now.timeIntervalSince(failed) < Self.failureBackoff {
            return reusedReading(
                settings: settings, fx: fx, now: now, interval: interval,
                note: "console unreachable, retrying later", debug: nil
            )
        }

        if !forceReload, let cached = cachedLoad,
           now.timeIntervalSince(cached.at) < interval,
           !spendJumped(since: cached.at, now: now, snapshot: snapshot),
           !resetPassed(OpenCodeParser.parse(payload: cached.payload, cap: settings.effectiveMonthlyCap),
                        loadedAt: cached.at, now: now) {
            let parsed = OpenCodeParser.parse(payload: cached.payload, cap: settings.effectiveMonthlyCap)
            if parsed.hasAny || parsed.needsSignIn || parsed.hasPlanValues {
                let reading = reading(from: cached.payload, settings: settings, fx: fx, stamp: cached.at, now: now)
                return liveAdjusted(reading, base: currentSpend(at: cached.at), snapshot: snapshot,
                                    stamp: cached.at, now: now, settings: settings)
            }
            // The cached load carried nothing usable; prefer the last good one.
            return reusedReading(
                settings: settings, fx: fx, now: now, interval: interval,
                note: "page unparsed", debug: parsed.debug
            )
        }

        // The bare console address shows no usage, so until the user pastes
        // their own Go page there's nothing to load; don't spend a webview on it.
        if urlString == Settings.defaultConsoleURL {
            return fallbackReading(settings: settings, fx: fx, now: now,
                                   note: "add your Console URL in Settings", debug: nil)
        }

        guard let url = URL(string: urlString) else {
            return fallbackReading(settings: settings, fx: fx, now: now, note: "invalid console URL", debug: urlString)
        }

        switch scrape(url: url) {
        case .success(let payload):
            setFailure(nil)
            // Stamped when the page was captured, not when the load started, so
            // spend made while it loaded (already in the console's numbers)
            // isn't added again by the live estimate.
            let captured = max(now, Date())
            // Cache every successful load so the interval gate holds even when
            // the page carries nothing we can parse.
            store(payload, at: captured, url: urlString)
            let parsed = OpenCodeParser.parse(payload: payload, cap: settings.effectiveMonthlyCap)
            if parsed.hasAny || parsed.needsSignIn || parsed.hasPlanValues {
                storeGood(payload, at: captured, url: urlString)
                return reading(from: payload, settings: settings, fx: fx, stamp: captured, now: captured)
            }
            return reusedReading(
                settings: settings, fx: fx, now: now, interval: interval,
                note: "page unparsed", debug: parsed.debug
            )
        case .failure(let error):
            setFailure(now)
            return reusedReading(
                settings: settings, fx: fx, now: now, interval: interval,
                note: error.localizedDescription,
                debug: "webview: \(error.localizedDescription)"
            )
        }
    }

    /// Reuses the last good load when one is recent enough, otherwise estimates.
    /// A reused reading is flagged (and its footnote explains why) so neither the
    /// popover nor the menu bar presents it as a fresh reading (SPEC §17). The
    /// reuse window is bounded so stale data is never resurrected indefinitely.
    private func reusedReading(settings: Settings, fx: FX, now: Date, interval: TimeInterval,
                               note: String, debug: String?) -> OpenCodeReading {
        if let good = currentGood(), good.url == settings.effectiveConsoleURL,
           now.timeIntervalSince(good.at) <= max(3 * interval, 3600) {
            var reading = liveAdjusted(
                reading(from: good.payload, settings: settings, fx: fx, stamp: good.at, now: now),
                base: currentSpend(at: good.at),
                snapshot: OpenCodeDatabase.snapshot(now: now, since: good.at),
                stamp: good.at, now: now, settings: settings
            )
            reading.reused = true
            let suffix = "last good load \(relativeAge(good.at, now: now)), refresh failed"
            let existing = reading.row.footnote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            reading.row.footnote = existing.isEmpty ? suffix : "\(existing) · \(suffix)"
            return reading
        }
        return fallbackReading(settings: settings, fx: fx, now: now, note: note, debug: debug)
    }

    // MARK: - Cache

    private func currentCache() -> (payload: ScrapePayload, at: Date, url: String)? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cached
    }

    private func currentGood() -> (payload: ScrapePayload, at: Date, url: String)? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return lastGood
    }

    private func store(_ payload: ScrapePayload, at date: Date, url: String) {
        let spend = OpenCodeDatabase.readSpend(now: date)
        cacheLock.lock()
        cached = (payload, date, url)
        cachedSpend = spend
        cacheLock.unlock()
    }

    private func storeGood(_ payload: ScrapePayload, at date: Date, url: String) {
        cacheLock.lock()
        lastGood = (payload, date, url)
        goodSpend = cachedSpend
        cacheLock.unlock()
    }

    private func currentFailure() -> Date? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return lastFailure
    }

    private func setFailure(_ date: Date?) {
        cacheLock.lock()
        lastFailure = date
        cacheLock.unlock()
    }

    /// Database spend recorded with the load stamped `date`, if any.
    private func currentSpend(at date: Date) -> OpenCodeSpend? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached, cached.at == date { return cachedSpend }
        if let lastGood, lastGood.at == date { return goodSpend }
        return nil
    }

    /// True when enough new Go spend has landed since the load at `since` that
    /// the console should be re-read now rather than at the next interval.
    /// Uses spend recorded after the load (not the net change of a rolling
    /// window), so older spend ageing out can't hide new use.
    private func spendJumped(since: Date, now: Date, snapshot: OpenCodeDBSnapshot?) -> Bool {
        guard now.timeIntervalSince(since) >= Self.minimumReloadGap, let snapshot else { return false }
        return snapshot.spentSince >= Self.reloadSpendJumpUSD || snapshot.limitHit
    }

    /// True when a window the console reported has since reset, so the cached
    /// numbers are known to be wrong and the page should be re-read.
    private func resetPassed(_ parsed: OpenCodeParsedUsage, loadedAt: Date, now: Date) -> Bool {
        [parsed.fiveHourResetIn, parsed.weekResetIn, parsed.monthResetIn]
            .compactMap { $0 }
            .contains { loadedAt.addingTimeInterval($0) <= now }
    }

    /// Brings a console reading up to date with what the local OpenCode
    /// database has recorded since that load: the console's used % plus the
    /// new Go spend measured against the window's dollar cap (from the page,
    /// else implied by the console % and the spend at load time, else the
    /// settings cap share). Both database sums are rolling windows, so spend
    /// ageing out of the window is subtracted too. A Go "usage limit exceeded"
    /// error since the load pins the 5h window to 0.
    private func liveAdjusted(_ reading: OpenCodeReading, base: OpenCodeSpend?, snapshot: OpenCodeDBSnapshot?,
                              stamp: Date, now: Date, settings: Settings) -> OpenCodeReading {
        guard reading.row.tag == .live, reading.fiveHourLeft != nil || reading.weekLeft != nil,
              now.timeIntervalSince(stamp) >= 60,
              let base, let snapshot else { return reading }

        // The manual cap override (SPEC §13) wins over console caps here too.
        let override = settings.opencodeOverride
        let fallbackCap = settings.effectiveMonthlyCap
        // Only spend recorded since the console load is added (gross). Old
        // local spend ageing out of a rolling sum is never handed back as
        // allowance; the next console load is what confirms any recovery.
        let spent = snapshot.spentSince
        func estimate(_ left: Double?, cap: Double?, then: Double, share: Double) -> Double? {
            guard let left else { return nil }
            let used = 100 - left
            let capUSD = override
                ? fallbackCap * share
                : (cap ?? (used >= 2 && then >= 0.05 ? then / (used / 100) : fallbackCap * share))
            guard capUSD > 0 else { return left }
            return leftPercent(used + spent / capUSD * 100)
        }

        var out = reading
        out.fiveHourLeft = estimate(reading.fiveHourLeft, cap: reading.capFiveHourUSD,
                                    then: base.fiveHour, share: 0.20)
        out.weekLeft = estimate(reading.weekLeft, cap: reading.capWeekUSD,
                                then: base.week, share: 0.50)
        let limitHit = snapshot.limitHit
        if limitHit { out.fiveHourLeft = 0 }

        guard limitHit || spent >= 0.005 else { return reading }

        let parts = Self.windowParts(five: out.fiveHourLeft, week: out.weekLeft,
                                     fiveReset: reading.fiveHourReset, weekReset: reading.weekReset)
        let note = limitHit
            ? "Go limit hit (OpenCode error)"
            : "est: $\(String(format: "%.2f", snapshot.spentSince)) spent since console check \(relativeAge(stamp, now: now))"
        let footnote = [reading.row.footnote, note].compactMap { $0 }.joined(separator: " · ")
        out.row = UsageRow(
            id: reading.row.id,
            title: reading.row.title,
            value: parts.joined(separator: " · "),
            footnote: footnote,
            tag: .estimated,
            updated: now,
            debug: reading.row.debug,
            alert: limitHit,
            // Stamped now, so the remaining budget is what's left of the
            // console reading's own (which already ends at the next reset).
            staleAfter: reading.row.staleAfter.map { max(0, stamp.addingTimeInterval($0).timeIntervalSince(now)) }
        )
        return out
    }

    private func storeLiveCap(_ cap: Double) {
        capLock.lock()
        liveCapMonthUSD = cap
        capLock.unlock()
    }

    private func currentLiveCap() -> Double? {
        capLock.lock()
        defer { capLock.unlock() }
        return liveCapMonthUSD
    }

    /// Builds the reading for a payload. `stamp` is when the page was actually
    /// loaded, so a reused cached result keeps its true age.
    private func reading(from payload: ScrapePayload, settings: Settings, fx: FX, stamp: Date, now: Date) -> OpenCodeReading {
        let cap = settings.effectiveMonthlyCap
        let parsed = OpenCodeParser.parse(payload: payload, cap: cap)
        if let liveCap = parsed.limitMonth { storeLiveCap(liveCap) }
        if parsed.needsSignIn {
            return OpenCodeReading(
                fiveHourLeft: nil,
                weekLeft: nil,
                planName: parsed.planName,
                monthlyPriceUSD: parsed.monthlyPrice,
                capFiveHourUSD: parsed.limitFiveHour,
                capWeekUSD: parsed.limitWeek,
                capMonthUSD: parsed.limitMonth,
                row: UsageRow(
                    id: id,
                    title: "OpenCode Go",
                    value: "needs sign-in",
                    footnote: "use “Sign in to OpenCode…”",
                    tag: .live,
                    updated: stamp,
                    debug: parsed.debug,
                    staleAfter: TimeInterval(settings.clampedOpenCodeRefreshMinutes * 60 * 2)
                )
            )
        }
        if parsed.hasAny {
            return primaryReading(
                parsed: parsed,
                now: stamp,
                staleAfter: TimeInterval(settings.clampedOpenCodeRefreshMinutes * 60 * 2)
            )
        }
        var fallback = fallbackReading(settings: settings, fx: fx, now: now, note: "page unparsed", debug: parsed.debug)
        fallback.planName = parsed.planName
        fallback.monthlyPriceUSD = parsed.monthlyPrice
        fallback.capFiveHourUSD = parsed.limitFiveHour
        fallback.capWeekUSD = parsed.limitWeek
        fallback.capMonthUSD = parsed.limitMonth
        if let plan = parsed.planName {
            fallback.row.footnote = [plan, fallback.row.footnote].compactMap { $0 }.joined(separator: " · ")
        }
        return fallback
    }

    // MARK: - Primary (webview)

    private func primaryReading(parsed: OpenCodeParsedUsage, now: Date, staleAfter: TimeInterval?) -> OpenCodeReading {
        let fiveLeft = parsed.fiveHourUsed.map(leftPercent)
        let weekLeft = parsed.weekUsed.map(leftPercent)
        let fiveReset = parsed.fiveHourResetIn.map { now.addingTimeInterval($0) }
        let weekReset = parsed.weekResetIn.map { now.addingTimeInterval($0) }
        let monthReset = parsed.monthResetIn.map { now.addingTimeInterval($0) }
        let parts = Self.windowParts(five: fiveLeft, week: weekLeft, fiveReset: fiveReset, weekReset: weekReset)
        // Once a window resets, the reading is known to be out of date.
        let untilReset = [fiveReset, weekReset, monthReset].compactMap { $0 }.min()
            .map { max(0, $0.timeIntervalSince(now)) }
        let freshness = [staleAfter, untilReset].compactMap { $0 }.min()

        var footnotes: [String] = []
        if let plan = parsed.planName, !plan.isEmpty { footnotes.append(plan) }
        if let used = parsed.monthUsed {
            footnotes.append("Month: \(percentLeft(used))% left" + (monthReset.map { " (resets \(shortDate($0)))" } ?? ""))
        }

        return OpenCodeReading(
            fiveHourLeft: fiveLeft,
            weekLeft: weekLeft,
            planName: parsed.planName,
            monthlyPriceUSD: parsed.monthlyPrice,
            capFiveHourUSD: parsed.limitFiveHour,
            capWeekUSD: parsed.limitWeek,
            capMonthUSD: parsed.limitMonth,
            fiveHourReset: fiveReset,
            weekReset: weekReset,
            monthReset: monthReset,
            row: UsageRow(
                id: id,
                title: "OpenCode Go",
                value: parts.isEmpty ? "no window data" : parts.joined(separator: " · "),
                footnote: footnotes.isEmpty ? "console page" : footnotes.joined(separator: " · "),
                tag: .live,
                updated: now,
                debug: parsed.debug,
                staleAfter: freshness
            )
        )
    }

    /// "5h: 0% left (resets 15:30)", "Week: 37% left (resets Sun 01:10)".
    static func windowParts(five: Double?, week: Double?, fiveReset: Date?, weekReset: Date?) -> [String] {
        var parts: [String] = []
        if let five {
            parts.append("5h: \(Int(five.rounded()))% left" + (fiveReset.map { " (resets \(clockTime($0)))" } ?? ""))
        }
        if let week {
            parts.append("Week: \(Int(week.rounded()))% left" + (weekReset.map { " (resets \(weekdayTime($0)))" } ?? ""))
        }
        return parts
    }

    private func leftPercent(_ used: Double) -> Double {
        max(0, min(100, 100 - used))
    }

    private func percentLeft(_ used: Double) -> Int {
        max(0, min(100, Int((100 - used).rounded())))
    }

    /// Blocking call onto the main thread where the webview lives.
    private func scrape(url: URL) -> Result<ScrapePayload, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<ScrapePayload, Error> = .failure(ScrapeError.timedOut)
        let key = UUID()

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                semaphore.signal()
                return
            }
            let scraper = OffscreenScraper(url: url) { outcome in
                lock.lock()
                result = outcome
                lock.unlock()
                self.activeScrapers[key] = nil
                semaphore.signal()
            }
            self.activeScrapers[key] = scraper
        }

        if semaphore.wait(timeout: .now() + 60) == .timedOut {
            DispatchQueue.main.async { [weak self] in self?.activeScrapers[key] = nil }
            return .failure(ScrapeError.timedOut)
        }

        lock.lock()
        let outcome = result
        lock.unlock()
        return outcome
    }

    // MARK: - Fallback (sqlite)

    private func fallbackReading(settings: Settings, fx: FX, now: Date, note: String, debug: String?) -> OpenCodeReading {
        // Live console cap replaces the settings cap unless the user forced the
        // manual override (SPEC §13 continued).
        let cap = (!settings.opencodeOverride ? (currentLiveCap() ?? settings.effectiveMonthlyCap) : settings.effectiveMonthlyCap)

        guard let spend = OpenCodeDatabase.readSpend(now: now) else {
            return OpenCodeReading(
                fiveHourLeft: nil,
                weekLeft: nil,
                planName: nil,
                monthlyPriceUSD: nil,
                capFiveHourUSD: nil,
                capWeekUSD: nil,
                capMonthUSD: nil,
                row: UsageRow(
                    id: id,
                    title: "OpenCode Go",
                    value: "not available",
                    footnote: note == "page unparsed" ? "no local database" : note,
                    tag: .none,
                    updated: nil,
                    debug: debug
                )
            )
        }

        let fiveCap = cap * 0.20
        let weekCap = cap * 0.50
        let monthCap = cap

        let monthDisplay = fx.display(Money(spend.month, "USD"))
        let capDisplay = fx.display(Money(monthCap, "USD"))
        let fiveDisplay = fx.display(Money(fiveCap, "USD"))
        let weekDisplay = fx.display(Money(weekCap, "USD"))
        let spentFive = fx.display(Money(spend.fiveHour, "USD"))
        let spentWeek = fx.display(Money(spend.week, "USD"))

        let monthText = "\(monthDisplay.text) of \(capDisplay.text) (est)"
        let footnote = "5h \(spentFive.text)/\(fiveDisplay.text) · Wk \(spentWeek.text)/\(weekDisplay.text)"
            + (note == "page unparsed" ? " · page unparsed" : "")

        return OpenCodeReading(
            fiveHourLeft: leftPercent(spend.fiveHour / fiveCap * 100),
            weekLeft: leftPercent(spend.week / weekCap * 100),
            planName: nil,
            monthlyPriceUSD: nil,
            capFiveHourUSD: nil,
            capWeekUSD: nil,
            capMonthUSD: nil,
            row: UsageRow(
                id: id,
                title: "OpenCode Go",
                value: monthText,
                footnote: footnote,
                tag: .estimated,
                updated: now,
                debug: debug
            )
        )
    }
}
