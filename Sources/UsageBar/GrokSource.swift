import Foundation

/// Grok's numeric value plus the finished row (SPEC §12).
struct GrokReading {
    var percentLeft: Double?
    /// `usage.grokPlanLabel` from the cache (SPEC §13 continued).
    var planName: String?
    var row: UsageRow
}

/// Row 2 — Grok Bot.
///
/// Reads exactly one file inside
/// `~/Library/Application Support/Grok Bot/sand-client-persistence/`:
/// the one whose RFC 4648 base32 filename decodes to a name ending in
/// `.weekly-usage.cache`. No other file there is ever opened.
final class GrokSource: UsageSource {
    let id = "grok"

    private let directory = usageBarHome
        .appendingPathComponent("Library/Application Support/Grok Bot/sand-client-persistence", isDirectory: true)

    func makeRow(settings: Settings, now: Date) -> UsageRow {
        reading(settings: settings, now: now).row
    }

    func reading(settings: Settings, now: Date) -> GrokReading {
        if let live = liveReading(settings: settings, now: now) { return live }
        return manualReading(settings: settings, now: now, note: "cache not found")
    }

    private func liveReading(settings: Settings, now: Date) -> GrokReading? {
        guard let file = weeklyUsageFile() else { return nil }
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let reading = ((json["value"] as? [String: Any])?["reading"] as? [String: Any])
        let usage = reading?["usage"] as? [String: Any]

        guard let percentUsed = doubleValue(usage?["percentUsed"]) else { return nil }
        let percentLeft = max(0, min(100, 100 - percentUsed))

        let reset = dateValue(usage?["nextResetMs"])
        let readAt = dateValue(reading?["readAtMs"]) ?? modificationDate(of: file) ?? now
        let plan = usage?["grokPlanLabel"] as? String

        var value = "\(fmtDecimal(percentLeft, 1))% left"
        if let plan, !plan.isEmpty { value += " · \(plan)" }
        let footnote = reset.map { "resets \(weekdayTime($0))" }

        return GrokReading(
            percentLeft: percentLeft,
            planName: plan,
            row: UsageRow(
                id: id,
                title: "Grok Bot",
                value: value,
                footnote: footnote,
                tag: .live,
                updated: readAt,
                debug: jsonSnippet(usage ?? json),
                // Stale when the weekly window resets, or after a day (SPEC §17).
                staleAfter: staleBudget(from: readAt, resets: [reset])
            )
        )
    }

    private func manualReading(settings: Settings, now: Date, note: String) -> GrokReading {
        guard let manual = settings.manualGrokPercentLeft else {
            return GrokReading(
                percentLeft: nil,
                planName: nil,
                row: UsageRow(
                    id: id,
                    title: "Grok Bot",
                    value: "not set",
                    footnote: note,
                    tag: .manual,
                    updated: nil
                )
            )
        }
        return GrokReading(
            percentLeft: manual,
            planName: nil,
            row: UsageRow(
                id: id,
                title: "Grok Bot",
                value: "\(fmtDecimal(manual, 1))% left",
                footnote: "manual value",
                tag: .manual,
                updated: nil
            )
        )
    }

    /// Locate the single cache blob without opening any other file.
    private func weeklyUsageFile() -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let candidates = entries.filter { $0.pathExtension == "blob" }

        var best: (url: URL, date: Date)?
        for candidate in candidates {
            let stem = candidate.deletingPathExtension().lastPathComponent
            guard !stem.isEmpty, stem.allSatisfy({ "abcdefghijklmnopqrstuvwxyz234567".contains($0) }),
                  let decoded = base32Decode(stem),
                  let name = String(data: decoded, encoding: .utf8),
                  name.hasSuffix(".weekly-usage.cache") else { continue }
            let date = modificationDate(of: candidate) ?? .distantPast
            if best == nil || date > best!.date {
                best = (candidate, date)
            }
        }
        return best?.url
    }
}
