import Foundation

/// OVH billing block nested in the `vps` object (SPEC §9).
///
/// Every field is optional, and the block may instead be `{"error": ...}`.
/// A missing field simply isn't shown.
struct VPSBilling {
    var service: String?
    var plan: String?
    var price: Double?
    var currency: String?
    var priceText: String?
    var period: String?
    var nextBillingDate: Date?
    var expirationDate: Date?
    var autoRenew: Bool?
    var state: String?
    var fetchedAt: Date?
    var stale: Bool?
    var error: String?

    var hasValue: Bool {
        service != nil || plan != nil || price != nil || currency != nil
            || priceText != nil || period != nil || nextBillingDate != nil
            || expirationDate != nil || autoRenew != nil || state != nil
            || fetchedAt != nil || stale != nil || error != nil
    }

    /// Parses the `"billing": { ... }` object. Returns nil when absent or empty.
    static func parse(_ any: Any?) -> VPSBilling? {
        guard let dict = any as? [String: Any] else { return nil }
        var b = VPSBilling()
        b.service = dict["service"] as? String
        b.plan = dict["plan"] as? String
        b.price = doubleValue(dict["price"])
        b.currency = dict["currency"] as? String
        b.priceText = dict["price_text"] as? String
        b.period = dict["period"] as? String
        b.nextBillingDate = dateValue(dict["next_billing_date"])
        b.expirationDate = dateValue(dict["expiration_date"])
        b.autoRenew = boolValue(dict["auto_renew"])
        b.state = dict["state"] as? String
        b.fetchedAt = dateValue(dict["fetched_at"])
        b.stale = boolValue(dict["stale"])
        b.error = dict["error"] as? String
        return b.hasValue ? b : nil
    }

    /// The live renewal date: next billing, else expiration.
    var renewalDate: Date? { nextBillingDate ?? expirationDate }

    /// Display text for the billing price in its own currency, e.g. "£3.90/mo".
    var priceDisplay: String? {
        let suffix = BillingPeriod(ovhPeriod: period)?.priceSuffix ?? "/mo"
        if let text = priceText?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            let collapsed = text.replacingOccurrences(of: " ", with: "")
            return collapsed + suffix
        }
        guard let price else { return nil }
        return "\(currencySymbol(effectiveCurrency))\(amount(price))\(suffix)"
    }

    /// The currency code, or one inferred from the price symbol when OVH omits
    /// the code. Empty when nothing can be inferred.
    var effectiveCurrency: String {
        if let currency = currency?.trimmingCharacters(in: .whitespacesAndNewlines), !currency.isEmpty {
            return currency.uppercased()
        }
        guard let text = priceText else { return "" }
        if text.contains("£") { return "GBP" }
        if text.contains("€") { return "EUR" }
        if text.contains("$") { return "USD" }
        return ""
    }

    /// A numeric amount, preferring `price` and falling back to a number parsed
    /// out of `price_text` (e.g. "£ 3.90").
    var numericPrice: Double? {
        if let price { return price }
        guard let text = priceText,
              let regex = try? NSRegularExpression(pattern: "([0-9]+(?:[.,][0-9]+)?)"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range].replacingOccurrences(of: ",", with: "."))
    }

    /// How many months one billing period covers (for a per-month total).
    var monthsPerPeriod: Double {
        switch BillingPeriod(ovhPeriod: period) {
        case .quarterly: return 3
        case .yearly: return 12
        default: return 1
        }
    }
}

/// A VPS price resolved from `settings.priceVPS` (MANUAL) or the OVH billing
/// block (LIVE), as a per-month `Money` in its original currency (SPEC §13).
struct VPSPrice {
    /// `nil` when only display text is known (no numeric amount to sum).
    var monthly: Money?
    /// The provider's own text, e.g. "£3.90/mo".
    var originalText: String
    var tag: SourceTag
}

extension VPSBilling {
    static func resolvePrice(settings: Settings, billing: VPSBilling?) -> VPSPrice? {
        if let manual = settings.priceVPS {
            let money = Money(manual, settings.priceCurrency(for: "VPS"))
            return VPSPrice(monthly: money, originalText: "\(formatMoney(money))/mo", tag: .manual)
        }
        guard let billing else { return nil }
        let currency = billing.effectiveCurrency
        guard let numeric = billing.numericPrice else {
            // Text-only price: still shown, but never folded into a total.
            if let text = billing.priceDisplay {
                return VPSPrice(monthly: nil, originalText: text, tag: .live)
            }
            return nil
        }
        let money = Money(numeric / billing.monthsPerPeriod, currency)
        let text = billing.priceDisplay ?? "\(formatMoney(money))/mo"
        return VPSPrice(monthly: money, originalText: text, tag: .live)
    }
}

/// Price/renewal/period summary shown in the popover and VPS row footnote.
struct VPSSummary {
    var priceText: String?
    /// Original amount + rate + source, e.g. "orig £3.90 @ 0.8893, ECB 2026-10-14".
    var priceDetail: String?
    var priceTag: SourceTag = .none
    var renewalText: String?
    var renewalTag: SourceTag = .none
    var periodLabel: String?

    static func make(settings: Settings, billing: VPSBilling?, fx: FX) -> VPSSummary {
        var summary = VPSSummary()

        if let resolved = VPSBilling.resolvePrice(settings: settings, billing: billing) {
            summary.priceTag = resolved.tag
            if let monthly = resolved.monthly {
                let display = fx.display(monthly)
                summary.priceText = "\(display.text)/mo"
                summary.priceDetail = display.detail
            } else {
                summary.priceText = resolved.originalText
            }
        }

        if let billing {
            if billing.autoRenew == false {
                let date = billing.renewalDate.map { isoDate($0) } ?? "the renewal date"
                summary.renewalText = "Manual renewal: pay before \(date)"
                summary.renewalTag = .live
            } else if billing.autoRenew == true {
                summary.renewalTag = .live
            }
        }

        // The due date is manual when the user pinned a date; otherwise it is
        // driven by OVH, so the period follows the billing block.
        if settings.vpsDueDate != nil {
            summary.periodLabel = settings.vpsBillingPeriod.label
        } else if let billing {
            if let label = BillingPeriod(ovhPeriod: billing.period)?.label {
                summary.periodLabel = label
            } else if let period = billing.period, !period.isEmpty {
                summary.periodLabel = period
            }
        }

        return summary
    }
}
