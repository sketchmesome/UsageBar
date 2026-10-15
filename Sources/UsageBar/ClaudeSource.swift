import Foundation

/// Claude's numeric windows plus the finished row, so the menu bar title can
/// reuse the same reading (SPEC §12).
struct ClaudeReading {
    var fiveHourLeft: Double?
    var weekLeft: Double?
    /// When the weekly window resets, when known.
    var weekReset: Date? = nil
    /// Plan name from `~/.claude.json` `oauthAccount.organizationType`
    /// (SPEC §13 continued).
    var planName: String?
    var row: UsageRow
}

/// Row 4 — Claude Code (STUB).
///
/// Reads `~/Library/Application Support/UsageBar/claude.json` if present,
/// tolerating key variants, otherwise falls back to manual settings. The plan
/// name is read (at most hourly) from `oauthAccount.organizationType` in
/// `~/.claude.json`; nothing else from that file is kept or logged.
final class ClaudeSource: UsageSource {
    let id = "claude"

    private let fileURL = SettingsStore.directory.appendingPathComponent("claude.json")
    /// Usage history written by the Claude **desktop app**. Claude Code run from
    /// the app is headless, so the terminal status line — and therefore
    /// `claude.json` — never updates; this file is the only local source in that
    /// case, so Claude Code is tracked whichever way it is run (SPEC §17).
    private let desktopUsageURL = usageBarHome
        .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    private let claudeJSON = usageBarHome.appendingPathComponent(".claude.json")
    private let planLock = NSLock()
    private var cachedAccount: (mtime: Date?, readAt: Date, plan: String?, org: String?)?
    func makeRow(settings: Settings, now: Date) -> UsageRow {
        reading(settings: settings, now: now).row
    }

    func reading(settings: Settings, now: Date, force: Bool = false) -> ClaudeReading {
        // Three sources, newest wins by its own timestamp. The usage API is the
        // only one that works when Claude Code runs inside the desktop app (it
        // renders no status line); the two local files cover the offline and
        // rate-limited cases. Comparing timestamps keeps a cached API snapshot
        // from beating a seconds-old status-line write.
        let api = apiReading(now: now, force: force)
        // An explicit refresh asked for live data: when the API actually answered
        // just now, use it rather than letting a local file written during the
        // request win on a timestamp. A cached snapshot (e.g. while rate-limited)
        // competes on its timestamp like the rest.
        if force, let api, (api.row.updated ?? .distantPast) >= now {
            return withWaitNote(api, now: now)
        }

        let candidates = [api, liveReading(now: now), desktopReading(now: now)]
            .compactMap { $0 }
        var best: ClaudeReading?
        for candidate in candidates {
            let at = candidate.row.updated ?? .distantPast
            if best == nil || at > (best!.row.updated ?? .distantPast) { best = candidate }
        }
        return withWaitNote(best ?? manualReading(settings: settings, planName: claudePlanName(now: now)), now: now)
    }

    /// Says why the number isn't moving while Anthropic has asked us to wait,
    /// whichever source ended up on the row.
    private func withWaitNote(_ reading: ClaudeReading, now: Date) -> ClaudeReading {
        guard let until = ClaudeUsageAPI.rateLimitedUntil(now: now) else { return reading }
        var out = reading
        let note = "Anthropic asked to wait · retry \(clockTime(until))"
        out.row.footnote = [reading.row.footnote, note].compactMap { $0 }.joined(separator: " · ")
        return out
    }

    /// Live usage straight from Anthropic's usage endpoint. Works whichever way
    /// Claude Code is run; the local sources only cover the offline case.
    private func apiReading(now: Date, force: Bool) -> ClaudeReading? {
        guard let snapshot = ClaudeUsageAPI.fetch(now: now, force: force) else { return nil }

        let fiveLeft = snapshot.fiveHour.map { max(0, min(100, 100 - $0.usedPercent)) }
        let weekLeft = snapshot.week.map { max(0, min(100, 100 - $0.usedPercent)) }

        var parts: [String] = []
        var footnotes: [String] = []
        if let fiveLeft {
            let reset = snapshot.fiveHour?.resetsAt.map { " (resets \(clockTime($0)))" } ?? ""
            parts.append("5h: \(fmtDecimal(fiveLeft, 1))% left\(reset)")
        }
        if let weekLeft {
            let reset = snapshot.week?.resetsAt.map { " (resets \(weekdayTime($0)))" } ?? ""
            footnotes.append("Week: \(fmtDecimal(weekLeft, 1))% left\(reset)")
        }

        let plan = claudePlanName(now: now)
        let footnoteParts = ([plan] + footnotes).compactMap { $0 }

        return ClaudeReading(
            fiveHourLeft: fiveLeft,
            weekLeft: weekLeft,
            weekReset: snapshot.week?.resetsAt,
            planName: plan,
            row: UsageRow(
                id: id,
                title: "Claude Code",
                value: parts.isEmpty ? "no data" : parts.joined(separator: " · "),
                footnote: footnoteParts.isEmpty ? "Anthropic usage API" : footnoteParts.joined(separator: " · "),
                tag: .live,
                // The snapshot's real fetch time, so a reused one keeps its age.
                updated: snapshot.fetchedAt,
                staleAfter: staleBudget(
                    from: snapshot.fetchedAt,
                    resets: [snapshot.fiveHour?.resetsAt, snapshot.week?.resetsAt]
                )
            )
        )
    }

    private func liveReading(now: Date) -> ClaudeReading? {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let five = window(json, keys: ["five_hour", "five_hour_window", "fiveHour", "5h", "primary"])
        let week = window(json, keys: ["seven_day", "seven_day_window", "sevenDay", "7d", "weekly", "secondary"])

        guard five != nil || week != nil else { return nil }

        var parts: [String] = []
        var footnotes: [String] = []

        if let five {
            parts.append("5h: \(fmtDecimal(five.left, 1))% left" + (five.reset.map { " (resets \(clockTime($0)))" } ?? ""))
        }
        if let week {
            footnotes.append("Week: \(fmtDecimal(week.left, 1))% left" + (week.reset.map { " (resets \(weekdayTime($0)))" } ?? ""))
        }

        let plan = claudePlanName(now: now)
        let footnoteParts = ([plan] + (footnotes.isEmpty ? [] : footnotes)).compactMap { $0 }

        return ClaudeReading(
            fiveHourLeft: five?.left,
            weekLeft: week?.left,
            weekReset: week?.reset,
            planName: plan,
            row: UsageRow(
                id: id,
                title: "Claude Code",
                value: parts.isEmpty ? "no data" : parts.joined(separator: " · "),
                footnote: footnoteParts.isEmpty ? "claude.json" : footnoteParts.joined(separator: " · "),
                tag: .live,
                updated: modificationDate(of: fileURL) ?? now,
                debug: jsonSnippet(json),
                // Stale once either window has rolled (SPEC §17); the file is
                // only rewritten when Claude Code renders a status line.
                staleAfter: staleBudget(
                    from: modificationDate(of: fileURL),
                    resets: [five?.reset, week?.reset]
                )
            )
        )
    }

    /// Usage snapshot written by the Claude **desktop app**
    /// (`~/Library/Application Support/Claude/plan-usage-history.json`): samples
    /// of `{t, org, u:{fh, sd}}`, where `fh`/`sd` are the 5h/7d used percentages.
    /// Only `t` and `u` are used; `org` is *matched* against the signed-in
    /// organisation (never stored or logged) so another organisation's usage
    /// can't be shown under this plan's name. The file carries no reset times, so
    /// staleness falls back to a 2h budget: it is written irregularly and a 5h
    /// window can roll well inside an hour.
    private func desktopReading(now: Date) -> ClaudeReading? {
        guard let data = try? Data(contentsOf: desktopUsageURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = json["samples"] as? [[String: Any]] else { return nil }

        let loggedInOrg = claudeOrgUUID(now: now)
        var matched: (at: Date, fiveUsed: Double?, weekUsed: Double?)?
        var anyOrg: (at: Date, fiveUsed: Double?, weekUsed: Double?)?
        // The history has no visible cap; only its tail can matter.
        for sample in samples.suffix(50) {
            guard let at = dateValue(sample["t"]),
                  // A future-dated sample would win every refresh and never age.
                  at <= now.addingTimeInterval(300),
                  let usage = sample["u"] as? [String: Any] else { continue }
            let fiveUsed = doubleValue(usage["fh"])
            let weekUsed = doubleValue(usage["sd"])
            // Ignore samples that carry no usable number, so one bad newest
            // entry can't blank the whole source.
            guard fiveUsed != nil || weekUsed != nil else { continue }

            let entry: (at: Date, fiveUsed: Double?, weekUsed: Double?) = (at, fiveUsed, weekUsed)
            if anyOrg == nil || at > anyOrg!.at { anyOrg = entry }
            if let loggedInOrg, (sample["org"] as? String) != loggedInOrg { continue }
            if matched == nil || at > matched!.at { matched = entry }
        }
        // When we know who's logged in, only their own samples count.
        guard let chosen = loggedInOrg == nil ? anyOrg : matched else { return nil }

        let fiveLeft = chosen.fiveUsed.map { max(0, min(100, 100 - $0)) }
        let weekLeft = chosen.weekUsed.map { max(0, min(100, 100 - $0)) }

        var parts: [String] = []
        var footnotes: [String] = []
        if let fiveLeft { parts.append("5h: \(fmtDecimal(fiveLeft, 1))% left") }
        if let weekLeft { footnotes.append("Week: \(fmtDecimal(weekLeft, 1))% left") }
        footnotes.append("Claude desktop app")

        let plan = claudePlanName(now: now)
        let footnoteParts = ([plan] + footnotes).compactMap { $0 }

        return ClaudeReading(
            fiveHourLeft: fiveLeft,
            weekLeft: weekLeft,
            planName: plan,
            row: UsageRow(
                id: id,
                title: "Claude Code",
                value: parts.isEmpty ? "no data" : parts.joined(separator: " · "),
                footnote: footnoteParts.joined(separator: " · "),
                tag: .live,
                updated: chosen.at,
                debug: "plan-usage-history: \(samples.count) samples",
                staleAfter: staleBudget(from: chosen.at, resets: [], backstop: 2 * 60 * 60)
            )
        )
    }

    private struct Window {
        var left: Double
        var reset: Date?
    }

    private func window(_ json: [String: Any], keys: [String]) -> Window? {
        for key in keys {
            guard let obj = json[key] as? [String: Any] else { continue }
            let used = doubleValue(obj["used_percentage"])
                ?? doubleValue(obj["used_percent"])
                ?? doubleValue(obj["utilization"])
                ?? doubleValue(obj["percent_used"])
            guard let used else { continue }
            let normalized = used
            let reset = dateValue(obj["resets_at"]) ?? dateValue(obj["reset_at"]) ?? dateValue(obj["resetsAt"])
            return Window(left: max(0, min(100, 100 - normalized)), reset: reset)
        }
        return nil
    }

    private func manualReading(settings: Settings, planName: String?) -> ClaudeReading {
        let five = settings.manualClaude5hLeft
        let week = settings.manualClaudeWeekLeft
        let footnoteParts = ([planName, "set manual values in Settings…"]).compactMap { $0 }
        guard five != nil || week != nil else {
            return ClaudeReading(
                fiveHourLeft: nil,
                weekLeft: nil,
                planName: planName,
                row: UsageRow(
                    id: id,
                    title: "Claude Code",
                    value: "not connected",
                    footnote: footnoteParts.joined(separator: " · "),
                    tag: .manual,
                    updated: nil
                )
            )
        }
        var parts: [String] = []
        var footnotes: [String] = []
        if let five { parts.append("5h: \(fmtDecimal(five, 1))% left") }
        if let week { footnotes.append("Week: \(fmtDecimal(week, 1))% left") }
        let parts2 = ([planName] + footnotes).compactMap { $0 }
        return ClaudeReading(
            fiveHourLeft: five,
            weekLeft: week,
            planName: planName,
            row: UsageRow(
                id: id,
                title: "Claude Code",
                value: parts.joined(separator: " · "),
                footnote: parts2.joined(separator: " · "),
                tag: .manual,
                updated: nil
            )
        )
    }

    // MARK: - Plan name (~/.claude.json)

    /// Reads ONLY `oauthAccount.organizationType` and `oauthAccount.organizationUuid`
    /// from `~/.claude.json` (SPEC §13 continued), at most once an hour and only
    /// when the file's mtime changed. Everything else is discarded and never logged.
    private func account(now: Date) -> (plan: String?, org: String?) {
        planLock.lock()
        let cached = cachedAccount
        planLock.unlock()
        if let cached, now.timeIntervalSince(cached.readAt) < 3600 { return (cached.plan, cached.org) }

        let mtime = modificationDate(of: claudeJSON)
        if let cached, let mtime, cached.mtime == mtime {
            // Unchanged since the last read: keep the values, reset the clock.
            storeAccount(plan: cached.plan, org: cached.org, mtime: mtime, now: now)
            return (cached.plan, cached.org)
        }

        guard let data = try? Data(contentsOf: claudeJSON),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            storeAccount(plan: nil, org: nil, mtime: mtime, now: now)
            return (nil, nil)
        }
        let oauth = json["oauthAccount"] as? [String: Any]
        let plan = Self.planName(from: oauth?["organizationType"] as? String)
        let org = oauth?["organizationUuid"] as? String
        storeAccount(plan: plan, org: org, mtime: mtime, now: now)
        return (plan, org)
    }

    private func claudePlanName(now: Date) -> String? { account(now: now).plan }

    private func claudeOrgUUID(now: Date) -> String? { account(now: now).org }

    private func storeAccount(plan: String?, org: String?, mtime: Date?, now: Date) {
        planLock.lock()
        cachedAccount = (mtime: mtime, readAt: now, plan: plan, org: org)
        planLock.unlock()
    }

    /// "claude_pro" → "Claude Pro"; an unknown value becomes "Claude <Value>".
    static func planName(from raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        var value = raw.lowercased()
        if value.hasPrefix("claude_") { value = String(value.dropFirst("claude_".count)) }
        else if value.hasPrefix("claude") { value = String(value.dropFirst("claude".count)) }
        value = value.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return "Claude" }
        let titled = value.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
        return "Claude \(titled)"
    }
}
