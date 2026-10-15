import Foundation

struct RefreshResult {
    var rows: [UsageRow]
    var title: String
    var updatedDueDate: Date?
    var vps: VPSStatus?
    var vpsConfigured: Bool
    var vpsNote: String?
    /// Parsed OVH billing block, when the endpoint returned one (SPEC §9).
    var billing: VPSBilling?
    /// Numeric values for the menu bar title (SPEC §12).
    var menuBarValues: MenuBarValues
    /// Resolved FX context used for this refresh (SPEC §13).
    var fx: FX
    /// Live plan/price values discovered this refresh (SPEC §13 continued).
    var live: LivePlanValues
    /// OpenCode Go $/h now vs usual, from the local database.
    var opencodePace: OpenCodePace?
}

/// Runs every source concurrently off the main thread and assembles one result.
/// The caller applies the result to the UI exactly once.
final class UsageEngine {
    private let codex = CodexSource()
    private let grok = GrokSource()
    private let opencode = OpenCodeSource()
    private let claude = ClaudeSource()
    private let deepseek = DeepSeekSource()
    private let spend = SpendSource()
    private let vps = VPSDueSource()
    private let fxService = FXService()

    private final class Box {
        let lock = NSLock()
        var slots: [Int: UsageRow] = [:]
        var codexReading: CodexReading?
        var claudeReading: ClaudeReading?
        var grokReading: GrokReading?
        var opencodeReading: OpenCodeReading?
        var opencodePace: OpenCodePace?
        var deepseekBalance: Money?
        var vps: VPSStatus?
        var billing: VPSBilling?
        var vpsConfigured = false
        var vpsNote: String?
    }

    /// - Parameter forceOpenCode: an explicit popover "Refresh" bypasses the
    ///   OpenCode interval and reloads the console webview (SPEC §10).
    /// - Parameter forceLive: an explicit popover "Refresh" also asks sources
    ///   with their own pacing (the Claude usage API) for fresh data now.
    func refresh(settings: Settings, now: Date, forceOpenCode: Bool = false, forceLive: Bool = false) -> RefreshResult {
        // FX rates are resolved once per refresh (network only when the cache is
        // older than 24 h) and shared by every money value (SPEC §13).
        let fx = FX.make(settings: settings, rates: fxService.rates(now: now))

        let box = Box()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.lanes.usagebar.sources", attributes: .concurrent)

        func submit(_ index: Int, _ work: @escaping () -> UsageRow) {
            group.enter()
            queue.async {
                let row = work()
                box.lock.lock()
                box.slots[index] = row
                box.lock.unlock()
                group.leave()
            }
        }

        submit(0) { [codex] in
            let reading = codex.reading(now: now, force: forceLive)
            box.lock.lock()
            box.codexReading = reading
            box.lock.unlock()
            return reading.row
        }
        submit(1) { [grok] in
            let reading = grok.reading(settings: settings, now: now)
            box.lock.lock()
            box.grokReading = reading
            box.lock.unlock()
            return reading.row
        }
        submit(2) { [opencode] in
            let reading = opencode.reading(settings: settings, now: now, forceReload: forceOpenCode, fx: fx)
            let pace = OpenCodeDatabase.pace(now: now)
            box.lock.lock()
            box.opencodeReading = reading
            box.opencodePace = pace
            box.lock.unlock()
            return reading.row
        }
        submit(3) { [claude] in
            let reading = claude.reading(settings: settings, now: now, force: forceLive)
            box.lock.lock()
            box.claudeReading = reading
            box.lock.unlock()
            return reading.row
        }
        submit(4) { [deepseek] in
            let outcome = deepseek.evaluate(settings: settings, now: now, fx: fx)
            box.lock.lock()
            box.vps = outcome.vps
            box.billing = outcome.billing
            box.vpsConfigured = outcome.vpsConfigured
            box.vpsNote = outcome.vpsNote
            box.deepseekBalance = outcome.balance
            box.lock.unlock()
            return outcome.row
        }

        group.wait()

        box.lock.lock()
        var slots = box.slots
        let reading = box.codexReading
        let claudeReading = box.claudeReading
        let grokReading = box.grokReading
        let opencodeReading = box.opencodeReading
        let opencodePace = box.opencodePace
        let deepseekBalance = box.deepseekBalance
        let billing = box.billing
        let vpsStatus = box.vps
        let vpsConfigured = box.vpsConfigured
        let vpsNote = box.vpsNote
        box.lock.unlock()

        // The VPS due date and spend both depend on the OVH billing block and
        // the live plan values, so they run after the other sources.
        let live = LivePlanValues(
            opencodeMonthlyPriceUSD: opencodeReading?.monthlyPriceUSD,
            opencodeCapFiveHourUSD: opencodeReading?.capFiveHourUSD,
            opencodeCapWeekUSD: opencodeReading?.capWeekUSD,
            opencodeCapMonthUSD: opencodeReading?.capMonthUSD,
            opencodePlanName: opencodeReading?.planName,
            codexPlanName: reading?.planName,
            claudePlanName: claudeReading?.planName,
            grokPlanName: grokReading?.planName
        )
        let due = vps.evaluate(settings: settings, now: now, billing: billing, fx: fx)
        let spendOutcome = spend.makeRow(settings: settings, fx: fx, billing: billing, live: live)
        slots[5] = spendOutcome.row
        slots[6] = due.row

        let rows = (0..<7).compactMap { slots[$0] }

        let menuBarValues = MenuBarValues(
            claude5hLeft: claudeReading?.fiveHourLeft,
            claudeWeekLeft: claudeReading?.weekLeft,
            codex5hLeft: reading?.fiveHourLeft.map(Double.init),
            codexWeekLeft: reading?.weekLeft.map(Double.init),
            // A reused OpenCode reading is not current: the menu bar shows "–"
            // rather than a number the refresh failed to confirm (SPEC §17).
            opencode5hLeft: opencodeReading?.reused == true ? nil : opencodeReading?.fiveHourLeft,
            opencodeWeekLeft: opencodeReading?.reused == true ? nil : opencodeReading?.weekLeft,
            grokPercentLeft: grokReading?.percentLeft,
            deepseekBalance: deepseekBalance,
            deepseekOriginalBalance: deepseekBalance,
            totalSpend: spendOutcome.total,
            vpsDays: due.days,
            vpsDiskUsedPercent: Self.diskUsedPercent(vpsStatus),
            claudeWeekReset: claudeReading?.weekReset,
            codexWeekReset: reading?.weekReset,
            opencodeWeekReset: opencodeReading?.reused == true ? nil : opencodeReading?.weekReset,
            grokReset: grokReading?.reset
        )

        return RefreshResult(
            rows: rows,
            title: Self.title(from: reading),
            updatedDueDate: due.updatedDueDate,
            vps: vpsStatus,
            vpsConfigured: vpsConfigured,
            vpsNote: vpsNote,
            billing: billing,
            menuBarValues: menuBarValues,
            fx: fx,
            live: live,
            opencodePace: opencodePace
        )
    }

    /// Percentage of the VPS disk in use, when both used and free are known.
    private static func diskUsedPercent(_ status: VPSStatus?) -> Double? {
        guard let used = status?.diskUsedGB, let free = status?.diskFreeGB, used + free > 0 else {
            return nil
        }
        return max(0, min(100, used / (used + free) * 100))
    }

    private static func title(from reading: CodexReading?) -> String {
        var parts: [String] = []
        if let five = reading?.fiveHourLeft { parts.append("C\(100 - five)") }
        if let week = reading?.weekLeft { parts.append("W\(100 - week)") }
        return parts.isEmpty ? "UsageBar" : parts.joined(separator: " ")
    }
}
