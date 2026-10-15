import Foundation

// MARK: - Money

/// An amount together with its currency code. Every money value the app
/// handles is passed around as a `Money` so a conversion is always explicit
/// (SPEC §13).
struct Money: Equatable {
    var amount: Double
    var currency: String

    init(_ amount: Double, _ currency: String) {
        self.amount = amount
        self.currency = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

/// Currency symbol shared by every money display. An unknown code keeps its
/// code (e.g. "CHF ") so no symbol is ever guessed.
func currencySymbol(_ currency: String) -> String {
    let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    switch code {
    case "USD": return "$"
    case "EUR": return "€"
    case "GBP": return "£"
    default: return code.isEmpty ? "" : "\(code) "
    }
}

func formatMoney(_ money: Money, decimals: Int = 2) -> String {
    "\(currencySymbol(money.currency))\(String(format: "%.\(decimals)f", money.amount))"
}

/// Whole-currency form for compact surfaces like the menu bar, e.g. "€14".
func formatMoneyCompact(_ money: Money) -> String {
    "\(currencySymbol(money.currency))\(String(format: "%.0f", money.amount.rounded()))"
}

// MARK: - Cached rates

/// Rates fetched from a keyless provider, all normalised to "units of a
/// currency per 1 EUR" (SPEC §13).
struct FXRates: Codable {
    var base: String = "EUR"
    /// Provider quote date (yyyy-MM-dd), used for the "ECB 2026-10-14" detail.
    var date: String
    var fetchedAt: Date
    /// "ECB" (frankfurter.dev) or "er-api" (open.er-api.com).
    var source: String
    /// Units of each currency per 1 EUR, e.g. `["USD": 1.16, "GBP": 0.85]`.
    var rates: [String: Double]
}

/// Loads and caches FX rates (SPEC §13).
///
/// Fetches at most once per 24 h, preferring the fresh `fx.json` cache. When a
/// fetch fails a stale cache is reused rather than dropping to nothing. No rate
/// is ever hard-coded.
final class FXService {
    static let fileURL = SettingsStore.directory.appendingPathComponent("fx.json")
    static let maxAge: TimeInterval = 24 * 60 * 60

    private let lock = NSLock()
    private var memory: FXRates?
    private var lastAttempt: Date?

    /// Fresh rates if any: the in-memory copy, the on-disk cache (< 24 h), or a
    /// freshly fetched set. Falls back to a stale cache when a fetch fails.
    func rates(now: Date) -> FXRates? {
        lock.lock()
        let cached = memory
        let attempted = lastAttempt
        lock.unlock()
        if let cached, now.timeIntervalSince(cached.fetchedAt) < Self.maxAge {
            return cached
        }

        let onDisk = Self.loadCache()
        if let onDisk, now.timeIntervalSince(onDisk.fetchedAt) < Self.maxAge {
            store(onDisk)
            return onDisk
        }

        if let attempted, now.timeIntervalSince(attempted) < Self.maxAge {
            return cached ?? onDisk
        }
        lock.lock()
        lastAttempt = now
        lock.unlock()

        if let fresh = fetch(now: now) {
            store(fresh)
            Self.saveCache(fresh)
            return fresh
        }

        // Fetch failed: a stale cache (memory first) beats no rates at all.
        if let cached { return cached }
        if let onDisk { store(onDisk); return onDisk }
        return nil
    }

    private func store(_ rates: FXRates) {
        lock.lock()
        memory = rates
        lock.unlock()
    }

    // MARK: - Providers

    private func fetch(now: Date) -> FXRates? {
        // Primary: frankfurter.dev (ECB reference rates), base EUR.
        if let json = Self.fetchJSON(urlString: "https://api.frankfurter.dev/v1/latest?from=EUR"),
           (json["base"] as? String)?.uppercased() == "EUR",
           let raw = json["rates"] as? [String: Any] {
            let rates = raw.compactMapValues { value -> Double? in
                guard let rate = doubleValue(value), rate > 0, rate.isFinite else { return nil }
                return rate
            }
            if !rates.isEmpty {
                return FXRates(
                    date: json["date"] as? String ?? isoDate(now),
                    fetchedAt: now,
                    source: "ECB",
                    rates: rates
                )
            }
        }

        // Fallback: open.er-api.com, still base EUR.
        if let json = Self.fetchJSON(urlString: "https://open.er-api.com/v6/latest/EUR"),
           (json["base_code"] as? String)?.uppercased() == "EUR",
           let raw = json["rates"] as? [String: Any] {
            let rates = raw.compactMapValues { value -> Double? in
                guard let rate = doubleValue(value), rate > 0, rate.isFinite else { return nil }
                return rate
            }
            if !rates.isEmpty {
                return FXRates(date: isoDate(now), fetchedAt: now, source: "er-api", rates: rates)
            }
        }
        return nil
    }

    private static func fetchJSON(urlString: String) -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            result = json
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 35) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            return nil
        }
        session.finishTasksAndInvalidate()
        return result
    }

    // MARK: - Cache file

    private static func loadCache() -> FXRates? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FXRates.self, from: data)
    }

    private static func saveCache(_ rates: FXRates) {
        try? FileManager.default.createDirectory(
            at: SettingsStore.directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(rates) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Converter

/// Everything needed to convert any amount into the display currency
/// (SPEC §13): the target currency, the currency entered prices are in, the
/// manual overrides, and the fetched rates.
struct FX {
    var displayCurrency: String
    var priceCurrency: String
    var overrides: [String: Double]
    var rates: FXRates?

    static func make(settings: Settings, rates: FXRates?) -> FX {
        FX(
            displayCurrency: settings.effectiveDisplayCurrency,
            priceCurrency: settings.effectivePriceCurrency,
            overrides: settings.fxOverrides,
            rates: rates
        )
    }

    var rateDate: String? { rates?.date }
    var sourceLabel: String { rates?.source ?? "manual" }

    /// e.g. "ECB 2026-10-14", or just the source when no date is known.
    var rateLabel: String {
        if let source = rates?.source, let date = rates?.date { return "\(source) \(date)" }
        return sourceLabel
    }

    /// Units of `code` per 1 EUR. A manual override wins over fetched rates.
    func perEUR(_ code: String) -> Double? {
        let code = code.uppercased()
        if code == "EUR" { return 1 }
        if let value = validated(overrides["EUR->\(code)"]) { return value }
        if let value = validated(overrides["\(code)->EUR"]) { return 1 / value }
        if let rate = validated(rates?.rates[code]) { return rate }
        return nil
    }

    /// The rate to multiply an amount in `source` by to get `target`.
    func rate(from source: String, to target: String) -> Double? {
        let source = source.uppercased(), target = target.uppercased()
        if source == target { return 1 }
        if let value = validated(overrides["\(source)->\(target)"]) { return value }
        if let value = validated(overrides["\(target)->\(source)"]) { return 1 / value }
        guard let s = perEUR(source), let t = perEUR(target), s > 0 else { return nil }
        return t / s
    }

    /// Converts into the display currency, or `nil` when no rate is available.
    func convert(_ money: Money, to target: String? = nil) -> Money? {
        let target = (target ?? displayCurrency).uppercased()
        guard let rate = rate(from: money.currency, to: target) else { return nil }
        return Money(money.amount * rate, target)
    }

    /// A money value rendered in the display currency, keeping the original in
    /// the detail when a conversion actually happened.
    func display(_ money: Money) -> MoneyDisplay {
        guard let converted = convert(money) else {
            return MoneyDisplay(money: money, detail: "no \(money.currency)→\(displayCurrency) rate")
        }
        var detail: String?
        if money.currency != converted.currency,
           let rate = rate(from: money.currency, to: converted.currency) {
            detail = "orig \(formatMoney(money)) @ \(String(format: "%.4f", rate)), \(conversionLabel(from: money.currency, to: converted.currency))"
        }
        return MoneyDisplay(money: converted, detail: detail)
    }

    private func conversionLabel(from source: String, to target: String) -> String {
        let pairs = ["\(source)->\(target)", "\(target)->\(source)",
                     "EUR->\(source)", "\(source)->EUR", "EUR->\(target)", "\(target)->EUR"]
        return pairs.contains { validated(overrides[$0]) != nil } ? "manual" : rateLabel
    }

    private func validated(_ value: Double?) -> Double? {
        guard let value, value > 0, value.isFinite else { return nil }
        return value
    }
}

/// A money value rendered for the display currency (SPEC §13).
struct MoneyDisplay {
    /// In the display currency when a rate was available, else the original.
    var money: Money
    /// The original amount + rate + source, when a conversion happened.
    var detail: String?

    var text: String { formatMoney(money) }
}
