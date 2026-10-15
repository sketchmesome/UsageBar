import Foundation

enum SourceTag: String {
    case live = "LIVE"
    case estimated = "EST"
    case manual = "MANUAL"
    /// Official list price from the plan table (SPEC §16).
    case list = "LIST"
    case none = "—"
}

struct UsageRow: Identifiable {
    let id: String
    let title: String
    var value: String
    var footnote: String?
    let tag: SourceTag
    let updated: Date?
    let debug: String?
    let alert: Bool
    /// How old `updated` may get before the value is shown as stale (SPEC §17).
    /// `nil` means the value never goes stale (manual entries, live fetches).
    let staleAfter: TimeInterval?

    init(
        id: String,
        title: String,
        value: String,
        footnote: String? = nil,
        tag: SourceTag = .none,
        updated: Date? = nil,
        debug: String? = nil,
        alert: Bool = false,
        staleAfter: TimeInterval? = nil
    ) {
        self.id = id
        self.title = title
        self.value = value
        self.footnote = footnote
        self.tag = tag
        self.updated = updated
        self.debug = debug
        self.alert = alert
        self.staleAfter = staleAfter
    }

    /// True when the underlying reading is older than this row's freshness
    /// budget. Requires both a timestamp and a budget, so manual/live-fetch
    /// rows (which carry no `updated`) are never flagged.
    func isStale(now: Date) -> Bool {
        guard let staleAfter, let updated else { return false }
        // A zero budget means "already out of date" (e.g. its window has reset).
        return staleAfter <= 0 || now.timeIntervalSince(updated) > staleAfter
    }
}

/// Optional VPS telemetry returned alongside the DeepSeek balance (SPEC §8).
/// Every field is optional; a missing field simply isn't shown.
struct VPSStatus {
    var diskUsedGB: Double?
    var diskFreeGB: Double?
    var memUsedMB: Double?
    var memTotalMB: Double?
    var load1: Double?
    var load5: Double?
    var load15: Double?
    var uptimeSeconds: Double?
    var cachedAt: Date?

    var hasAnyValue: Bool {
        diskUsedGB != nil || diskFreeGB != nil
            || memUsedMB != nil || memTotalMB != nil
            || load1 != nil || load5 != nil || load15 != nil
            || uptimeSeconds != nil || cachedAt != nil
    }

    /// Parses the `"vps": { ... }` object. Returns nil when absent or empty.
    static func parse(_ any: Any?) -> VPSStatus? {
        guard let dict = any as? [String: Any] else { return nil }
        var status = VPSStatus()
        status.diskUsedGB = doubleValue(dict["disk_used_gb"])
        status.diskFreeGB = doubleValue(dict["disk_free_gb"])
        status.memUsedMB = doubleValue(dict["mem_used_mb"])
        status.memTotalMB = doubleValue(dict["mem_total_mb"])
        status.load1 = doubleValue(dict["load1"])
        status.load5 = doubleValue(dict["load5"])
        status.load15 = doubleValue(dict["load15"])
        status.uptimeSeconds = doubleValue(dict["uptime_s"])
        status.cachedAt = dateValue(dict["cached_at"])
        return status.hasAnyValue ? status : nil
    }

    // MARK: - Display lines

    var diskLine: String? {
        switch (diskUsedGB, diskFreeGB) {
        case let (used?, free?):
            return "\(fmtDecimal(used, 1)) GB used / \(fmtDecimal(free, 1)) GB free"
        case let (used?, nil):
            return "\(fmtDecimal(used, 1)) GB used"
        case let (nil, free?):
            return "\(fmtDecimal(free, 1)) GB free"
        default:
            return nil
        }
    }

    var ramLine: String? {
        let used = memUsedMB.map { $0 / 1024.0 }
        let total = memTotalMB.map { $0 / 1024.0 }
        switch (used, total) {
        case let (u?, t?):
            return "\(fmtDecimal(u, 1)) / \(fmtDecimal(t, 1)) GB"
        case let (u?, nil):
            return "\(fmtDecimal(u, 1)) GB"
        case let (nil, t?):
            return "\(fmtDecimal(t, 1)) GB total"
        default:
            return nil
        }
    }

    var loadLine: String? {
        let parts = [load1, load5, load15].compactMap { $0 }.map { fmtDecimal($0, 2) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var uptimeLine: String? {
        guard let seconds = uptimeSeconds, seconds >= 0 else { return nil }
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

/// Live plan names and OpenCode price/cap values discovered during a refresh
/// (SPEC §13 continued). Missing fields simply keep the settings fallback.
struct LivePlanValues {
    var opencodeMonthlyPriceUSD: Double?
    var opencodeCapFiveHourUSD: Double?
    var opencodeCapWeekUSD: Double?
    var opencodeCapMonthUSD: Double?
    var opencodePlanName: String?
    var codexPlanName: String?
    var claudePlanName: String?
    var grokPlanName: String?
}

enum BillingPeriod: String, Codable, CaseIterable, Identifiable {
    case monthly
    case quarterly
    case yearly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .monthly: return "Monthly"
        case .quarterly: return "Quarterly"
        case .yearly: return "Yearly"
        }
    }

    /// Short price suffix for a period, e.g. "/mo" (SPEC §9).
    var priceSuffix: String {
        switch self {
        case .monthly: return "/mo"
        case .quarterly: return "/qtr"
        case .yearly: return "/yr"
        }
    }

    /// Maps an OVH period code (`P1M`/`P3M`/`P1Y`) to a billing period.
    init?(ovhPeriod: String?) {
        guard let period = ovhPeriod?.trimmingCharacters(in: .whitespaces).uppercased(), !period.isEmpty else {
            return nil
        }
        switch period {
        case "P1M": self = .monthly
        case "P3M": self = .quarterly
        case "P1Y", "P12M": self = .yearly
        default: return nil
        }
    }

    func advance(_ date: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: date) ?? date
        case .quarterly:
            return calendar.date(byAdding: .month, value: 3, to: date) ?? date
        case .yearly:
            return calendar.date(byAdding: .year, value: 1, to: date) ?? date
        }
    }
}
