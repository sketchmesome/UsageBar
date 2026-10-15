import Foundation

/// One usage window's used% and, when the page shows a `$a / $b` pair, its cap.
struct WindowValues {
    var used: Double?
    var cap: Double?
    /// "Resets in 1h 42m" next to the window, relative to the page load.
    var resetIn: TimeInterval?
}

struct OpenCodeParsedUsage {
    var fiveHourUsed: Double?
    var weekUsed: Double?
    var monthUsed: Double?
    var limitFiveHour: Double?
    var limitWeek: Double?
    var limitMonth: Double?
    var fiveHourResetIn: TimeInterval?
    var weekResetIn: TimeInterval?
    var monthResetIn: TimeInterval?
    var planName: String?
    var monthlyPrice: Double?
    var needsSignIn = false
    var debug: String = ""

    var hasPlanValues: Bool {
        planName != nil || monthlyPrice != nil || limitFiveHour != nil
            || limitWeek != nil || limitMonth != nil
    }

    var hasAny: Bool {
        fiveHourUsed != nil || weekUsed != nil || monthUsed != nil
    }
}

/// Tolerant parser for whatever the OpenCode console page renders (SPEC §13
/// continued: plan name, monthly price, and dollar limits/caps).
enum OpenCodeParser {
    static func parse(payload: ScrapePayload, cap: Double) -> OpenCodeParsedUsage {
        var result = OpenCodeParsedUsage()
        result.debug = payload.debugSnippet

        // Prefer numeric fields captured from the fetch hook.
        let hook = hookWindows(payload.hook)
        // Fall back to reading the rendered text.
        let text = textWindows(payload.text)

        result.fiveHourUsed = hook.five.used ?? text.five.used
        result.weekUsed = hook.week.used ?? text.week.used
        result.monthUsed = hook.month.used ?? text.month.used

        result.limitFiveHour = hook.five.cap ?? text.five.cap
        result.limitWeek = hook.week.cap ?? text.week.cap
        result.limitMonth = hook.month.cap ?? text.month.cap

        result.fiveHourResetIn = text.five.resetIn
        result.weekResetIn = text.week.resetIn
        result.monthResetIn = text.month.resetIn

        result.planName = hookPlanName(payload.hook) ?? textPlanName(payload.text)
        result.monthlyPrice = hookMonthlyPrice(payload.hook) ?? textMonthlyPrice(payload.text)

        if !result.hasAny {
            let lowered = payload.text.lowercased()
            let signIn = lowered.contains("sign in") || lowered.contains("sign-in")
                || lowered.contains("log in") || lowered.contains("login")
            if signIn, firstPercent(payload.text) == nil { result.needsSignIn = true }
        }
        return result
    }

    // MARK: - Text parsing

    static func textWindows(_ text: String) -> (five: WindowValues, week: WindowValues, month: WindowValues) {
        var five = WindowValues()
        var week = WindowValues()
        var month = WindowValues()
        guard let labels = try? NSRegularExpression(
            pattern: "5[- ]?h(our)?|rolling|week|month", options: [.caseInsensitive]
        ) else { return (five, week, month) }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        // A countdown such as "Resets in 5h 42m" is not a window label.
        let matches = labels.matches(in: text, range: range).filter { match in
            let ns = text as NSString
            let lineStart = ns.lineRange(for: NSRange(location: match.range.location, length: 0)).location
            let prefix = ns.substring(with: NSRange(location: lineStart, length: match.range.location - lineStart))
            return !prefix.lowercased().contains("reset")
        }
        for (index, match) in matches.enumerated() {
            guard let labelRange = Range(match.range, in: text) else { continue }
            let end = index + 1 < matches.count ? matches[index + 1].range.location : range.length
            let nearbyRange = NSRange(location: match.range.location, length: end - match.range.location)
            guard let nearby = Range(nearbyRange, in: text) else { continue }
            // Never borrow a value from the next window's label.
            let window = text[nearby].components(separatedBy: .newlines).prefix(4).joined(separator: " ")
            guard var values = extractWindow(window), values.used != nil || values.cap != nil else { continue }
            values.resetIn = resetInterval(window)
            let label = text[labelRange].lowercased()
            if label.contains("month") {
                if month.used == nil { month = values }
            } else if label.contains("week") {
                if week.used == nil { week = values }
            } else if five.used == nil {
                five = values
            }
        }
        return (five, week, month)
    }

    /// "Resets in 3d 11h", "resets in 1h 42m", "Resets in 2 hours 59 minutes",
    /// "resets in 0m" → seconds. 0 means the reset is imminent.
    static func resetInterval(_ string: String) -> TimeInterval? {
        let unitPattern = "(\\d+)\\s*(days?|d|hours?|hrs?|h|minutes?|mins?|m)\\b"
        guard let regex = try? NSRegularExpression(
            pattern: "resets?\\s+in\\s+((?:\\d+\\s*(?:days?|d|hours?|hrs?|h|minutes?|mins?|m)\\b[\\s,]*(?:and\\s+)?)+)",
            options: [.caseInsensitive]
        ), let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let spanRange = Range(match.range(at: 1), in: string),
              let unit = try? NSRegularExpression(pattern: unitPattern, options: [.caseInsensitive])
        else { return nil }
        let span = String(string[spanRange])
        var seconds: TimeInterval = 0
        var matched = false
        for part in unit.matches(in: span, range: NSRange(span.startIndex..., in: span)) {
            guard let n = Range(part.range(at: 1), in: span).flatMap({ Double(span[$0]) }),
                  let u = Range(part.range(at: 2), in: span).map({ span[$0].lowercased() }) else { continue }
            matched = true
            seconds += n * (u.hasPrefix("d") ? 86_400 : u.hasPrefix("h") ? 3_600 : 60)
        }
        return matched ? seconds : nil
    }

    /// A window's used% and cap from either `$a / $b` or `NN%`.
    static func extractWindow(_ string: String) -> WindowValues? {
        if let pair = dollarPair(string) { return pair }
        if let percent = firstPercent(string) { return WindowValues(used: percent, cap: nil) }
        return nil
    }

    /// Backwards-compatible used-only view.
    static func extractUsed(_ string: String) -> Double? {
        extractWindow(string)?.used
    }

    private static func dollarPair(_ string: String) -> WindowValues? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\$\\s*([0-9]+(?:\\.[0-9]+)?)\\s*/\\s*\\$\\s*([0-9]+(?:\\.[0-9]+)?)"
        ) else { return nil }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: range),
              let aRange = Range(match.range(at: 1), in: string),
              let bRange = Range(match.range(at: 2), in: string),
              let used = Double(string[aRange]),
              let total = Double(string[bRange]),
              total > 0 else { return nil }
        return WindowValues(used: min(100, max(0, used / total * 100)), cap: total)
    }

    private static func firstPercent(_ string: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)\\s*%") else { return nil }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: range),
              let valueRange = Range(match.range(at: 1), in: string),
              let value = Double(string[valueRange]) else { return nil }
        return min(100, max(0, value))
    }

    /// A monthly price in the page text, e.g. "$10/month" or "$10/mo".
    static func textMonthlyPrice(_ text: String) -> Double? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\$\\s*([0-9]+(?:\\.[0-9]+)?)\\s*(?:/|per\\s+)?\\s*(?:mo(?:nth)?)\\b",
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[valueRange])
    }

    /// The OpenCode Go plan name from the page text (e.g. "Go", "Go Plus").
    static func textPlanName(_ text: String) -> String? {
        // Most specific first.
        for candidate in ["Go Plus", "Go Max", "Go Pro"] where text.range(of: candidate, options: .caseInsensitive) != nil {
            return candidate
        }
        if let regex = try? NSRegularExpression(pattern: "(?i)\\bplan\\b[^\\n]{0,30}?\\bGo\\b"),
           regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil {
            return "Go"
        }
        // A standalone "Go" alongside a dollar price is a reasonable signal.
        if text.range(of: "Go", options: [.caseInsensitive]) != nil, textMonthlyPrice(text) != nil {
            return "Go"
        }
        return nil
    }

    // MARK: - JSON hook parsing

    static func hookWindows(_ hook: [[String: Any]]) -> (five: WindowValues, week: WindowValues, month: WindowValues) {
        var five = WindowValues()
        var week = WindowValues()
        var month = WindowValues()

        func record(used: Double?, cap: Double?, context: String) {
            let context = context.lowercased()
            let isMonth = context.contains("month") || context.contains("30d")
            let isWeek = context.contains("week") || context.contains("7d") || context.contains("seven")
            let isFive = context.contains("5h") || context.contains("five")
                || context.contains("rolling") || context.contains("hour")
            if isMonth {
                if month.used == nil { month.used = used }
                if month.cap == nil { month.cap = cap }
            } else if isWeek {
                if week.used == nil { week.used = used }
                if week.cap == nil { week.cap = cap }
            } else if isFive {
                if five.used == nil { five.used = used }
                if five.cap == nil { five.cap = cap }
            }
        }

        func scan(_ any: Any, context: String) {
            if let object = any as? [String: Any] {
                let labels = ["window", "name", "type", "period", "label"]
                    .compactMap { object[$0] as? String }.joined(separator: ".")
                let context = context + "." + labels
                let keys = object.keys.sorted()
                let numbers = keys.compactMap { key -> (String, Double)? in
                    guard let value = doubleValue(object[key]) else { return nil }
                    return (key.lowercased(), value)
                }
                // A limit alone is a cap, not usage. Monetary/count fields need a denominator.
                let used = numbers.first { $0.0.contains("used") && !$0.0.contains("percent") && !$0.0.contains("pct") }
                let limit = numbers.first {
                    !$0.0.contains("percent") && !$0.0.contains("pct")
                        && ($0.0.contains("limit") || $0.0.contains("cap") || $0.0 == "total")
                }
                for (key, value) in numbers {
                    if (key.contains("percent") || key.contains("pct")), !key.contains("limit") && !key.contains("cap") {
                        let percent = key.contains("left") || key.contains("remaining") ? 100 - value : value
                        if (0...100).contains(percent) { record(used: percent, cap: nil, context: context + "." + key) }
                    } else if key.contains("utiliz"), (0...1).contains(value) {
                        record(used: value * 100, cap: nil, context: context + "." + key)
                    }
                }
                if let used, let limit, limit.1 > 0 {
                    record(used: nil, cap: limit.1, context: context)
                    record(used: min(100, max(0, used.1 / limit.1 * 100)), cap: limit.1, context: context)
                } else if let cap = limit?.1, cap > 0 {
                    record(used: nil, cap: cap, context: context)
                }
                for key in keys {
                    if let value = object[key] { scan(value, context: context + "." + key) }
                }
            } else if let array = any as? [Any] {
                for value in array { scan(value, context: context) }
            }
        }

        // The most recent response supersedes earlier fetches.
        for entry in hook.reversed() {
            guard let body = entry["body"] as? String,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            scan(json, context: entry["url"] as? String ?? "")
        }
        return (five, week, month)
    }

    /// First string value under a key mentioning "plan" in the hook responses.
    static func hookPlanName(_ hook: [[String: Any]]) -> String? {
        for entry in hook.reversed() {
            guard let body = entry["body"] as? String,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let name = firstString(in: json, matching: { $0.contains("plan") }) { return name }
        }
        return nil
    }

    /// First numeric value under a key mentioning "price" or "monthly".
    static func hookMonthlyPrice(_ hook: [[String: Any]]) -> Double? {
        for entry in hook.reversed() {
            guard let body = entry["body"] as? String,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let value = firstNumber(in: json, matching: { $0.contains("price") || $0.contains("monthly") }) {
                return value
            }
        }
        return nil
    }

    private static func firstString(in any: Any, matching predicate: (String) -> Bool) -> String? {
        if let object = any as? [String: Any] {
            let keys = object.keys.sorted()
            for key in keys where predicate(key.lowercased()) {
                if let value = object[key] as? String, !value.isEmpty { return value }
            }
            for key in keys {
                if let value = object[key], let found = firstString(in: value, matching: predicate) { return found }
            }
        } else if let array = any as? [Any] {
            for value in array {
                if let found = firstString(in: value, matching: predicate) { return found }
            }
        }
        return nil
    }

    private static func firstNumber(in any: Any, matching predicate: (String) -> Bool) -> Double? {
        if let object = any as? [String: Any] {
            let keys = object.keys.sorted()
            for key in keys where predicate(key.lowercased()) {
                if let value = doubleValue(object[key]) { return value }
            }
            for key in keys {
                if let value = object[key], let found = firstNumber(in: value, matching: predicate) { return found }
            }
        } else if let array = any as? [Any] {
            for value in array {
                if let found = firstNumber(in: value, matching: predicate) { return found }
            }
        }
        return nil
    }
}
