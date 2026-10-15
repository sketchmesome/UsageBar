import Foundation

struct VPSDueOutcome {
    var row: UsageRow
    /// Non-nil when a stored manual due date was advanced and should be persisted.
    var updatedDueDate: Date?
    /// The effective due date (manual override or OVH billing), if any.
    var dueDate: Date?
    /// Whole days until the due date, for the menu bar title (SPEC §12).
    var days: Int?
    /// Source of the effective due date (MANUAL override vs LIVE billing).
    var tag: SourceTag
    var alert: Bool
    /// Resolved price/renewal/period info for the row footnote and popover.
    var summary: VPSSummary
}

/// Row 7 — VPS due date (SPEC §7 + §9).
///
/// `settings.vpsDueDate` overrides OVH: when set it keeps the rolling advance
/// logic. Otherwise the OVH `billing.next_billing_date ?? expiration_date`
/// drives the due date, with no rolling. The row footnote carries the price,
/// due, and renewal source tags; the summary is reused by the popover.
struct VPSDueSource {
    let id = "vps"

    func evaluate(
        settings: Settings,
        now: Date,
        calendar: Calendar = .current,
        billing: VPSBilling? = nil,
        fx: FX
    ) -> VPSDueOutcome {
        let summary = VPSSummary.make(settings: settings, billing: billing, fx: fx)

        var due: Date?
        var tag: SourceTag = .none
        var updatedDueDate: Date?
        let startOfToday = calendar.startOfDay(for: now)

        if let manual = settings.vpsDueDate {
            // Manual override: keep rolling the date forward one period.
            var value = manual
            var advanced = false
            while value < startOfToday {
                let next = settings.vpsBillingPeriod.advance(value, calendar: calendar)
                guard next > value else { break }
                value = next
                advanced = true
            }
            due = value
            tag = .manual
            if advanced { updatedDueDate = value }
        } else if let live = billing?.renewalDate {
            // Live OVH date: no rolling required.
            due = live
            tag = .live
        }

        guard let due else {
            return VPSDueOutcome(
                row: UsageRow(
                    id: id,
                    title: "VPS",
                    value: "not set",
                    footnote: "set a due date in Settings…",
                    tag: .none,
                    updated: nil
                ),
                updatedDueDate: nil,
                dueDate: nil,
                days: nil,
                tag: .none,
                alert: false,
                summary: summary
            )
        }

        let days = calendar.dateComponents(
            [.day],
            from: startOfToday,
            to: calendar.startOfDay(for: due)
        ).day ?? 0
        let alert = days <= 3

        var parts: [String] = []
        if let period = summary.periodLabel { parts.append("\(period) billing") }
        if let price = summary.priceText {
            var pricePart = "price \(price) (\(summary.priceTag.rawValue))"
            if let detail = summary.priceDetail { pricePart += " · \(detail)" }
            parts.append(pricePart)
        }
        parts.append("due \(isoDate(due)) (\(tag.rawValue))")
        if let renewal = summary.renewalText {
            parts.append("\(renewal) (\(summary.renewalTag.rawValue))")
        } else if summary.renewalTag == .live {
            parts.append("auto-renew (LIVE)")
        }
        let footnote = parts.joined(separator: " · ")

        let updated = tag == .manual ? nil : (billing?.fetchedAt ?? now)

        return VPSDueOutcome(
            row: UsageRow(
                id: id,
                title: "VPS",
                value: "Due in \(days) day\(days == 1 ? "" : "s") (\(shortDate(due)))",
                footnote: footnote,
                tag: tag,
                updated: updated,
                alert: alert
            ),
            updatedDueDate: updatedDueDate,
            dueDate: due,
            days: days,
            tag: tag,
            alert: alert,
            summary: summary
        )
    }
}
