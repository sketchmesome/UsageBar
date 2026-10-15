import Foundation

/// Live Claude usage from Anthropic's own usage endpoint
/// (`https://api.anthropic.com/api/oauth/usage`), authenticated with the OAuth
/// token Claude Code keeps in the login Keychain.
///
/// This is the only source that works no matter how Claude Code is run. The
/// terminal status line never renders inside the Claude desktop app (it runs
/// Claude Code headless), and the desktop app's own usage history is written only
/// occasionally — so neither can track live usage from that surface.
///
/// The token is read from the Keychain, never logged and never persisted by this
/// app, and is cached until shortly before it expires so the Keychain is touched
/// rarely. The endpoint rate-limits, so requests are throttled and a rate-limit
/// response backs off. Every failure returns nil, and the caller falls back to
/// the local sources — this source never invents or guesses a value.
enum ClaudeUsageAPI {
    struct Window {
        var usedPercent: Double
        var resetsAt: Date?
    }

    struct Snapshot {
        var fiveHour: Window?
        var week: Window?
        /// When the values were actually fetched. The caller stamps the row with
        /// this and compares it against the local sources, so a reused snapshot
        /// neither looks fresher nor wins over newer local data.
        var fetchedAt: Date
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"
    private static let requestTimeout: TimeInterval = 10
    private static let keychainTimeout: TimeInterval = 5

    private static let lock = NSLock()
    private static var cachedToken: (value: String, expiresAt: Date?)?
    private static var cachedSnapshot: Snapshot?
    /// When we last *attempted* a request, success or not, so a run of failures
    /// can't become a request on every refresh.
    private static var lastAttempt: Date?
    /// Our own stand-down (expired token, unreadable Keychain). An explicit
    /// refresh may retry through it.
    private static var blockedUntil: Date?
    /// The server's stand-down after a 429. Honoured even by an explicit
    /// refresh, since it is the endpoint telling us to wait.
    private static var rateLimitedUntil: Date?
    /// 429s in a row, for the doubling stand-down. Reset by a success.
    private static var consecutiveRateLimits = 0

    /// Between requests; also the window in which a snapshot may be reused.
    /// Just under 3 min: the endpoint rate-limits, so background refreshes
    /// don't ask more often than this (an explicit Refresh always may).
    private static let minimumInterval: TimeInterval = 170
    /// Even an explicit Refresh waits this long between requests, so clicking
    /// it repeatedly can't hammer the endpoint.
    private static let forcedMinimumInterval: TimeInterval = 30
    /// A cached snapshot older than this is not shown as live at all — better to
    /// fall back to a local source than to label stale numbers LIVE.
    /// Covers the longest rate-limit stand-down, so a 429 keeps showing the last
    /// real reading (with its age) rather than an older local file.
    private static let maxCacheAge: TimeInterval = 1800
    /// Stand-down after a 429 when the server gives no `Retry-After`: 5 min,
    /// doubling on each further 429 in a row, up to 30 min.
    private static let rateLimitBackoff: TimeInterval = 300
    private static let maxRateLimitBackoff: TimeInterval = 1800
    /// An expired token is replaced by Claude Code on its next run, so retry
    /// soon — no request is sent while expired, only a cheap Keychain re-read.
    private static let expiredTokenBackoff: TimeInterval = 300
    /// A Keychain that cannot be read must not be retried often, or it may
    /// prompt the user every time.
    private static let credentialBackoff: TimeInterval = 3600

    /// Why we have (or haven't) a credential, which decides how long to wait.
    private enum Credential {
        case ok(String)
        case expired
        case unavailable
    }

    /// Fetches the live windows, or nil when anything goes wrong.
    ///
    /// `force` is set by an explicit user refresh, which asks for live data and
    /// so ignores the pacing below. Background refreshes keep the pacing, since
    /// the endpoint rate-limits.
    static func fetch(now: Date, force: Bool = false) -> Snapshot? {
        lock.lock()
        let cached = cachedSnapshot
        let blocked = blockedUntil
        let rateLimited = rateLimitedUntil
        let claimed = lastAttempt
        // A 429 is the server telling us to wait, so even an explicit refresh
        // honours it. The other stand-downs are ours, and a refresh may retry.
        let rateLimitedNow = rateLimited.map { now < $0 } ?? false
        let blockedNow = !force && (blocked.map { now < $0 } ?? false)
        let gap = force ? forcedMinimumInterval : minimumInterval
        let tooSoon = claimed.map { elapsed(from: $0, to: now) < gap } ?? false
        // Claim and decide under one lock hold, so two callers can't both spend
        // a request.
        if !rateLimitedNow, !blockedNow, !tooSoon { lastAttempt = now }
        lock.unlock()

        // Waiting: keep showing the last real reading rather than nothing.
        if rateLimitedNow || blockedNow { return reusableCache(cached, now: now) }
        if tooSoon { return reusableCache(cached, now: now) }

        switch credential(now: now) {
        case .ok(let token):
            return request(token: token, now: now)
        case .expired:
            backOff(now: now, by: expiredTokenBackoff)
            return nil
        case .unavailable:
            backOff(now: now, by: credentialBackoff)
            return nil
        }
    }

    private static func request(token: String, now: Date) -> Snapshot? {
        let (status, retryAfter, body) = get(token: token)
        // The response's real arrival time. Stamping the refresh's start time
        // would let a local file written during the request look newer.
        let acquiredAt = Date()

        if status == 401 || status == 403 {
            // Rejected despite looking valid; drop it and retry soon, since
            // Claude Code replaces it in the Keychain.
            lock.lock(); cachedToken = nil; lock.unlock()
            backOff(now: now, by: expiredTokenBackoff)
            return nil
        }
        if status == 429 {
            lock.lock()
            let doubling = rateLimitBackoff * pow(2, Double(consecutiveRateLimits))
            consecutiveRateLimits += 1
            let cached = cachedSnapshot
            lock.unlock()
            // Anchored at the response's arrival, as Retry-After is relative to it.
            rateLimit(now: acquiredAt, by: retryAfter.map { max(60, $0) } ?? min(maxRateLimitBackoff, doubling))
            return reusableCache(cached, now: now)
        }
        guard status == 200, let body, let snapshot = parse(body, fetchedAt: acquiredAt) else { return nil }

        lock.lock()
        cachedSnapshot = snapshot
        blockedUntil = nil          // a success clears every stand-down
        rateLimitedUntil = nil
        consecutiveRateLimits = 0
        lock.unlock()
        return snapshot
    }

    /// When Anthropic's rate limit lets us ask again, if we're waiting on it.
    static func rateLimitedUntil(now: Date) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return rateLimitedUntil.flatMap { $0 > now ? $0 : nil }
    }

    /// The server's stand-down after a rate limit — kept separate from our own
    /// stand-downs because an explicit refresh must still honour it.
    private static func rateLimit(now: Date, by seconds: TimeInterval) {
        lock.lock()
        let candidate = now.addingTimeInterval(seconds)
        rateLimitedUntil = max(rateLimitedUntil ?? candidate, candidate)
        lock.unlock()
    }

    /// The last snapshot, if it is recent enough and still has a live window.
    private static func reusableCache(_ cached: Snapshot?, now: Date) -> Snapshot? {
        guard let cached, elapsed(from: cached.fetchedAt, to: now) <= maxCacheAge else { return nil }
        return live(cached, now: now)
    }

    private static func backOff(now: Date, by seconds: TimeInterval) {
        lock.lock()
        // The deadline is "now + delay", never "existing deadline + delay":
        // otherwise a burst of 429s would stack up into hours of stand-down.
        let candidate = now.addingTimeInterval(seconds)
        blockedUntil = max(blockedUntil ?? candidate, candidate)
        lock.unlock()
    }

    /// Non-negative elapsed time, so a backward clock jump can't wedge a gate.
    private static func elapsed(from start: Date, to now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(start))
    }

    // MARK: - Freshness

    /// A window whose reset has passed carries a percentage that is certainly
    /// obsolete, so it is dropped rather than shown.
    private static func live(_ window: Window?, now: Date) -> Window? {
        guard let window else { return nil }
        if let reset = window.resetsAt, reset <= now { return nil }
        return window
    }

    /// The snapshot with any reset window removed, or nil when nothing is left.
    private static func live(_ snapshot: Snapshot, now: Date) -> Snapshot? {
        let five = live(snapshot.fiveHour, now: now)
        let week = live(snapshot.week, now: now)
        guard five != nil || week != nil else { return nil }
        return Snapshot(fiveHour: five, week: week, fetchedAt: snapshot.fetchedAt)
    }

    // MARK: - Credential

    /// The Claude Code OAuth token, cached until within five minutes of expiry.
    /// An already-expired token is never sent — only Claude Code can replace it,
    /// so when the cached one is stale we re-read the Keychain to pick up its
    /// refresh rather than assuming the worst.
    private static func credential(now: Date) -> Credential {
        lock.lock()
        let cached = cachedToken
        lock.unlock()
        if let cached {
            if let expiry = cached.expiresAt {
                if expiry.timeIntervalSince(now) > 300 { return .ok(cached.value) }
            } else {
                return .ok(cached.value)
            }
        }

        guard let raw = readKeychain(), let parsed = parseCredential(raw) else { return .unavailable }
        lock.lock(); cachedToken = parsed; lock.unlock()
        if let expiry = parsed.expiresAt, expiry <= now { return .expired }
        return .ok(parsed.value)
    }

    /// Bounded on purpose: `security` can stall on an authorization dialog, and
    /// this must never be able to hang a refresh (the engine waits for every
    /// source, and a stuck refresh suppresses all later ones). stdout is drained
    /// on another queue, so output larger than the pipe buffer can't deadlock it.
    private static func readKeychain() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        let box = DataBox()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue(label: "com.lanes.usagebar.keychain-read").async {
            box.set(out.fileHandleForReading.readDataToEndOfFile())
            read.signal()
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        let timedOut = exited.wait(timeout: .now() + keychainTimeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
        }
        // The reader ends once the write end closes (process exit or kill).
        guard read.wait(timeout: .now() + 1) == .success, !timedOut else { return nil }
        guard process.terminationStatus == 0 else { return nil }
        return box.string
    }

    /// `{"claudeAiOauth":{"accessToken":…,"expiresAt":<ms>}}` — only the token and
    /// its expiry are kept; nothing else from the blob is read or logged.
    private static func parseCredential(_ raw: String) -> (value: String, expiresAt: Date?)? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expiry = doubleValue(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return (token, expiry)
    }

    /// Small locked holder for the pipe reader's result.
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        var string: String? {
            lock.lock(); defer { lock.unlock() }
            return String(data: data, encoding: .utf8)
        }
    }

    // MARK: - Request

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }

    private static func get(token: String) -> (status: Int, retryAfter: TimeInterval?, body: [String: Any]?) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let semaphore = DispatchSemaphore(value: 0)
        var status = 0
        var retryAfter: TimeInterval?
        var body: [String: Any]?

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout + 5
        let session = URLSession(configuration: config)
        let task = session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse else { return }
            status = http.statusCode
            if let value = http.value(forHTTPHeaderField: "Retry-After") {
                // Either delay-seconds or an HTTP-date (RFC 9110 §10.2.3).
                retryAfter = Double(value.trimmingCharacters(in: .whitespaces))
                    ?? httpDate(value).map { $0.timeIntervalSinceNow }
            }
            guard let data else { return }
            body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        task.resume()
        if semaphore.wait(timeout: .now() + requestTimeout + 5) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            return (0, nil, nil)
        }
        session.finishTasksAndInvalidate()
        return (status, retryAfter, body)
    }

    // MARK: - Parse

    private static func parse(_ json: [String: Any], fetchedAt: Date) -> Snapshot? {
        let five = window(json["five_hour"])
        let week = window(json["seven_day"])
        guard five != nil || week != nil else { return nil }
        return Snapshot(fiveHour: five, week: week, fetchedAt: fetchedAt)
    }

    private static func window(_ any: Any?) -> Window? {
        guard let dict = any as? [String: Any],
              let used = doubleValue(dict["utilization"]) else { return nil }
        return Window(usedPercent: used, resetsAt: dateValue(dict["resets_at"]))
    }
}
