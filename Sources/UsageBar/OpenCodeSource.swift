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
        if !forceReload, let cached = currentCache(), cached.url == urlString,
           now.timeIntervalSince(cached.at) < interval {
            let parsed = OpenCodeParser.parse(payload: cached.payload, cap: settings.effectiveMonthlyCap)
            if parsed.hasAny || parsed.needsSignIn || parsed.hasPlanValues {
                return reading(from: cached.payload, settings: settings, fx: fx, stamp: cached.at, now: now)
            }
            // The cached load carried nothing usable; prefer the last good one.
            return reusedReading(
                settings: settings, fx: fx, now: now, interval: interval,
                note: "page unparsed", debug: parsed.debug
            )
        }

        guard let url = URL(string: urlString) else {
            return fallbackReading(settings: settings, fx: fx, now: now, note: "invalid console URL", debug: urlString)
        }

        switch scrape(url: url) {
        case .success(let payload):
            // Cache every successful load so the interval gate holds even when
            // the page carries nothing we can parse.
            store(payload, at: now, url: urlString)
            let parsed = OpenCodeParser.parse(payload: payload, cap: settings.effectiveMonthlyCap)
            if parsed.hasAny || parsed.needsSignIn || parsed.hasPlanValues {
                storeGood(payload, at: now, url: urlString)
                return reading(from: payload, settings: settings, fx: fx, stamp: now, now: now)
            }
            return reusedReading(
                settings: settings, fx: fx, now: now, interval: interval,
                note: "page unparsed", debug: parsed.debug
            )
        case .failure(let error):
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
            var reading = reading(from: good.payload, settings: settings, fx: fx, stamp: good.at, now: now)
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
        cacheLock.lock()
        cached = (payload, date, url)
        cacheLock.unlock()
    }

    private func storeGood(_ payload: ScrapePayload, at date: Date, url: String) {
        cacheLock.lock()
        lastGood = (payload, date, url)
        cacheLock.unlock()
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

        var parts: [String] = []
        if let fiveLeft { parts.append("5h: \(Int(fiveLeft.rounded()))% left") }
        if let weekLeft { parts.append("Week: \(Int(weekLeft.rounded()))% left") }

        var footnotes: [String] = []
        if let plan = parsed.planName, !plan.isEmpty { footnotes.append(plan) }
        if let used = parsed.monthUsed { footnotes.append("Month: \(percentLeft(used))% left") }

        return OpenCodeReading(
            fiveHourLeft: fiveLeft,
            weekLeft: weekLeft,
            planName: parsed.planName,
            monthlyPriceUSD: parsed.monthlyPrice,
            capFiveHourUSD: parsed.limitFiveHour,
            capWeekUSD: parsed.limitWeek,
            capMonthUSD: parsed.limitMonth,
            row: UsageRow(
                id: id,
                title: "OpenCode Go",
                value: parts.isEmpty ? "no window data" : parts.joined(separator: " · "),
                footnote: footnotes.isEmpty ? "console page" : footnotes.joined(separator: " · "),
                tag: .live,
                updated: now,
                debug: parsed.debug,
                staleAfter: staleAfter
            )
        )
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
