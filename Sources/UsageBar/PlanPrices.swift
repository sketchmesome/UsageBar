import Foundation

/// An official monthly list price for a detected plan (SPEC §16).
///
/// Every entry cites the public pricing page it was verified against, and no
/// price is ever invented: an unrecognised plan yields `nil`, leaving the price
/// "not set". Prices in the table are USD and are converted for display by the
/// shared FX layer.
struct PlanListPrice: Equatable {
    /// Provider name for the footnote (e.g. "Claude").
    var provider: String
    /// The detected plan identifier the entry is keyed on (e.g. "claude_pro").
    var planKey: String
    /// Official monthly list price in USD.
    var usdMonthly: Double
    /// Public page the price was verified against.
    var sourceURL: String
    /// Human plan label (e.g. "Claude Pro").
    var displayName: String

    /// The source URL without its scheme or trailing slash, e.g.
    /// "claude.com/pricing".
    var sourceLabel: String {
        sourceURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// The footnote detail for a list price, e.g.
    /// "orig $20 list, claude.com/pricing".
    var detail: String {
        "orig \(PlanPrices.formatUSD(usdMonthly)) list, \(sourceLabel)"
    }
}

/// Static "detected plan → official monthly list price" table (SPEC §16).
///
/// Lookups are deliberately tolerant: callers may pass the raw detected value
/// (`"claude_pro"`, `"plus"`, `"grok_max"`) or the display label this app
/// derives from it (`"Claude Pro"`, `"ChatGPT Plus"`). Anything unrecognised
/// returns `nil` so the spend row stays honest.
enum PlanPrices {
    /// Caveat appended to the Claude/ChatGPT footnote when a list price is used.
    static let usListNote = "US list price; local EUR/VAT pricing may differ"

    // MARK: - Claude  (~/.claude.json oauthAccount.organizationType)
    // verified 2026-10-14 // https://claude.com/pricing
    //   claude_pro → USD 20 (monthly billing)
    //   claude_max (5x) → USD 100 ("From $100")
    //   unknown types → nil

    static func claude(_ organizationType: String?) -> PlanListPrice? {
        guard let key = normalized(organizationType, stripping: "claude") else { return nil }
        switch key {
        case "pro":
            return PlanListPrice(
                provider: "Claude", planKey: "claude_pro", usdMonthly: 20,
                sourceURL: "https://claude.com/pricing", displayName: "Claude Pro"
            )
        case "max", "max (5x)", "max 5x":
            return PlanListPrice(
                provider: "Claude", planKey: "claude_max", usdMonthly: 100,
                sourceURL: "https://claude.com/pricing", displayName: "Claude Max (5x)"
            )
        default:
            return nil
        }
    }

    // MARK: - Codex / ChatGPT  (rate_limits.plan_type)
    // verified 2026-10-14
    //   plus → USD 20  // https://help.openai.com/en/articles/6950777-chatgpt-plus
    //   go   → USD 8   // https://openai.com/index/introducing-chatgpt-go/
    //   pro  → USD 200 // https://openai.com/index/introducing-chatgpt-go/
    //   other types → nil

    static func codex(_ planType: String?) -> PlanListPrice? {
        guard let key = normalized(planType, stripping: "chatgpt") else { return nil }
        switch key {
        case "plus":
            return PlanListPrice(
                provider: "ChatGPT", planKey: "plus", usdMonthly: 20,
                sourceURL: "https://help.openai.com/en/articles/6950777-chatgpt-plus",
                displayName: "ChatGPT Plus"
            )
        case "go":
            return PlanListPrice(
                provider: "ChatGPT", planKey: "go", usdMonthly: 8,
                sourceURL: "https://openai.com/index/introducing-chatgpt-go/",
                displayName: "ChatGPT Go"
            )
        case "pro":
            return PlanListPrice(
                provider: "ChatGPT", planKey: "pro", usdMonthly: 200,
                sourceURL: "https://openai.com/index/introducing-chatgpt-go/",
                displayName: "ChatGPT Pro"
            )
        default:
            return nil
        }
    }

    // MARK: - Grok Bot  (grokPlanLabel)
    // verified 2026-10-14 // https://x.ai/news/x-subscription
    //   "Grok Bot Plan" identifies no priced tier → nil
    //   exact X Subscription names: Premium 30, Super 100, Ultra 200

    static func grok(_ planLabel: String?) -> PlanListPrice? {
        guard let planLabel else { return nil }
        switch planLabel {
        case "Premium":
            return PlanListPrice(
                provider: "Grok Bot", planKey: "premium", usdMonthly: 30,
                sourceURL: "https://x.ai/news/x-subscription", displayName: "X Premium"
            )
        case "Super":
            return PlanListPrice(
                provider: "Grok Bot", planKey: "super", usdMonthly: 100,
                sourceURL: "https://x.ai/news/x-subscription", displayName: "X Super"
            )
        case "Ultra":
            return PlanListPrice(
                provider: "Grok Bot", planKey: "ultra", usdMonthly: 200,
                sourceURL: "https://x.ai/news/x-subscription", displayName: "X Ultra"
            )
        default:
            return nil
        }
    }

    // MARK: - OpenCode  (console plan)
    // verified 2026-10-14 // https://opencode.ai/go
    //   Go → USD 10; the live console price wins whenever it is parsed.
    //   When the page did not identify a plan at all, Go is the default.

    static func opencode(_ planName: String?) -> PlanListPrice? {
        if planName == nil { return goEntry }
        guard let key = normalized(planName, stripping: "opencode") else { return nil }
        return key == "go" ? goEntry : nil
    }

    private static let goEntry = PlanListPrice(
        provider: "OpenCode", planKey: "go", usdMonthly: 10,
        sourceURL: "https://opencode.ai/go", displayName: "OpenCode Go"
    )

    // MARK: - Helpers

    /// "$20" for whole dollars, else "$8.50".
    static func formatUSD(_ amount: Double) -> String {
        let symbol = currencySymbol("USD")
        if amount == amount.rounded() { return "\(symbol)\(Int(amount))" }
        return "\(symbol)\(String(format: "%.2f", amount))"
    }

    /// Lowercases and strips an optional provider prefix so both the raw key and
    /// the display label normalise the same way ("claude_pro"/"Claude Pro" →
    /// "pro"), plus a trailing "subscription"/"plan" qualifier.
    private static func normalized(_ raw: String?, stripping provider: String) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        var value = raw
        for prefix in ["\(provider)_", "\(provider) ", "\(provider)-"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        for suffix in [" subscription", " plan", " tier"] where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
        }
        value = value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
