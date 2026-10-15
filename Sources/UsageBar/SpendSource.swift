import Foundation

/// Row 6 — Spend. Sums only the filled monthly prices, in the display currency
/// (SPEC §13); nothing is ever invented.
///
/// Price precedence for each service (SPEC §16): the manual setting (when the
/// user filled it in) → the live value (OpenCode console / OVH API) → the
/// official list price from `PlanPrices` (tagged LIST) → "not set".
///
/// - Claude / ChatGPT / Grok Bot / Other are manual, entered in
///   `settings.priceCurrency`; with no manual price they may fall back to a
///   plan list price.
/// - OpenCode is LIVE when the console page reported a price, else its list
///   price (Go → USD 10); any entered manual price wins.
/// - VPS is MANUAL (`settings.priceVPS`) or LIVE (OVH billing), in its own
///   currency (e.g. GBP) and converted with the shared FX rates.
///
/// Amounts that cannot be converted stay in their original currency, and the
/// total then reads e.g. "€13.55/mo + £3.90".
struct SpendSource {
    let id = "spend"

    struct Outcome {
        var row: UsageRow
        /// Total in the display currency, for the menu bar `totalSpend` item (§13).
        var total: String?
    }

    private struct Line {
        var name: String
        /// Original amount, or nil when only display text is known.
        var money: Money?
        /// Text-only price (no numeric amount to sum).
        var text: String?
        var tag: SourceTag
        /// Overrides the FX detail string (list prices cite their source page).
        var detailOverride: String?
        /// Extra footnote note (e.g. the US-list-price VAT caveat).
        var note: String?
    }

    func makeRow(
        settings: Settings,
        fx: FX,
        billing: VPSBilling? = nil,
        live: LivePlanValues = LivePlanValues()
    ) -> Outcome {
        var lines: [Line] = [
            planLine(
                name: "Claude",
                manual: settings.priceClaude,
                list: PlanPrices.claude(live.claudePlanName),
                fx: fx,
                note: PlanPrices.usListNote
            ),
            planLine(
                name: "ChatGPT",
                manual: settings.priceChatGPT,
                list: PlanPrices.codex(live.codexPlanName),
                fx: fx,
                note: PlanPrices.usListNote
            ),
            openCodeLine(settings: settings, fx: fx, live: live),
            planLine(
                name: "Grok Bot",
                manual: settings.priceGrokBot,
                list: PlanPrices.grok(live.grokPlanName),
                fx: fx,
                note: nil
            )
        ]

        if let resolved = VPSBilling.resolvePrice(settings: settings, billing: billing) {
            lines.append(Line(
                name: "VPS",
                money: resolved.monthly,
                text: resolved.monthly == nil ? resolved.originalText : nil,
                tag: resolved.tag
            ))
        } else {
            lines.append(Line(name: "VPS", money: nil, text: nil, tag: .manual))
        }

        lines.append(planLine(name: "Other", manual: settings.priceOther, list: nil, fx: fx, note: nil))

        var total = 0.0
        var leftoverAmounts: [String: Double] = [:]
        var leftoverTexts: [String] = []
        var setCount = 0
        var footnotes: [String] = []
        var noteShown = false

        for line in lines {
            if let money = line.money {
                setCount += 1
                let display = fx.display(money)
                var rendered = footnote(for: line, display: display)
                if let note = line.note, !noteShown {
                    rendered += " · \(note)"
                    noteShown = true
                }
                footnotes.append(rendered)
                if display.money.currency == fx.displayCurrency {
                    total += display.money.amount
                } else {
                    leftoverAmounts[display.money.currency, default: 0] += display.money.amount
                }
            } else if let text = line.text {
                setCount += 1
                leftoverTexts.append(text)
                footnotes.append("\(line.name) \(text) (\(line.tag.rawValue))")
            } else {
                footnotes.append("\(line.name) not set (\(line.tag.rawValue))")
            }
        }

        var totalText = "\(formatMoney(Money(total, fx.displayCurrency)))/mo"
        let extras = leftoverAmounts.sorted { $0.key < $1.key }.map { formatMoney(Money($0.value, $0.key)) }
            + leftoverTexts
        if !extras.isEmpty {
            totalText += " + " + extras.joined(separator: " + ")
        }

        let row = UsageRow(
            id: id,
            title: "Spend",
            value: "\(totalText) (\(setCount) of 6 set)",
            footnote: footnotes.isEmpty ? "all fields empty" : footnotes.joined(separator: " · "),
            tag: .none,
            updated: nil
        )

        // Include every currency: a partial converted subtotal is not a total.
        var compact: [String] = []
        if lines.contains(where: { $0.money.flatMap { fx.convert($0) } != nil }) {
            compact.append(formatMoneyCompact(Money(total, fx.displayCurrency)))
        }
        compact += leftoverAmounts.sorted { $0.key < $1.key }.map {
            formatMoneyCompact(Money($0.value, $0.key))
        }
        compact += leftoverTexts
        return Outcome(row: row, total: compact.isEmpty ? nil : compact.joined(separator: " + "))
    }

    // MARK: - Line builders

    /// Precedence (SPEC §16): manual → official list price → not set. None of
    /// these services exposes a live price today (OpenCode/VPS do, below).
    private func planLine(
        name: String,
        manual: Double?,
        list: PlanListPrice?,
        fx: FX,
        note: String?
    ) -> Line {
        if let manual {
            return Line(name: name, money: Money(manual, fx.priceCurrency), text: nil, tag: .manual)
        }
        if let list {
            return Line(
                name: name,
                money: Money(list.usdMonthly, "USD"),
                text: nil,
                tag: .list,
                detailOverride: list.detail,
                note: note
            )
        }
        return Line(name: name, money: nil, text: nil, tag: .manual)
    }

    /// OpenCode precedence (SPEC §16): manual → live
    /// console price → official list price (Go → USD 10) → not set.
    private func openCodeLine(settings: Settings, fx: FX, live: LivePlanValues) -> Line {
        if let manual = settings.priceOpenCode {
            return Line(name: "OpenCode", money: Money(manual, fx.priceCurrency), text: nil, tag: .manual)
        }
        if let livePrice = live.opencodeMonthlyPriceUSD {
            return Line(name: "OpenCode", money: Money(livePrice, "USD"), text: nil, tag: .live)
        }
        if let list = PlanPrices.opencode(live.opencodePlanName) {
            return Line(
                name: "OpenCode",
                money: Money(list.usdMonthly, "USD"),
                text: nil,
                tag: .list,
                detailOverride: list.detail
            )
        }
        return Line(name: "OpenCode", money: nil, text: nil, tag: .manual)
    }

    /// A spend footnote line: converted value, original detail, and source tag.
    /// List prices carry their own "orig $20 list, <source>" detail.
    private func footnote(for line: Line, display: MoneyDisplay) -> String {
        var parts = ["\(line.name) \(display.text)"]
        if let detail = line.detailOverride ?? display.detail {
            parts.append("(\(detail))")
        }
        parts.append("(\(line.tag.rawValue))")
        return parts.joined(separator: " ")
    }
}
