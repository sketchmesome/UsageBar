import Darwin
import Foundation

/// Live Codex rate limits, read from the local `codex app-server`.
///
/// The app server exposes the account's limits over stdio JSON-RPC through
/// `account/rateLimits/read` — an account read that spends no model turn. That
/// matters twice over: Codex's limits otherwise only arrive as response headers
/// on real API calls, and the Codex *desktop app* writes no local rollout, so a
/// rollout-only source cannot see usage from that surface at all.
///
/// The server is spawned per read, given the handshake and one request, then
/// terminated (escalating to SIGKILL if it won't go). Every wait is bounded, so a
/// wedged or slow server can never hang a refresh or leave a process behind. Any
/// failure returns nil and the caller falls back to the rollout.
enum CodexAppServer {
    struct Window {
        var usedPercent: Double
        var windowMinutes: Double?
        var resetsAt: Date?
    }

    struct Snapshot {
        var primary: Window?
        var secondary: Window?
        var planType: String?
        var fetchedAt: Date
    }

    private static let handshakeTimeout: TimeInterval = 10
    private static let responseTimeout: TimeInterval = 20
    private static let terminationGrace: TimeInterval = 2
    private static let minimumInterval: TimeInterval = 100
    /// A cached snapshot older than this is not worth showing as live.
    private static let maxCacheAge: TimeInterval = 1200

    private static let lock = NSLock()
    private static var cachedSnapshot: Snapshot?
    private static var lastAttempt: Date?

    /// `force` is set by an explicit user refresh, which ignores the pacing.
    static func fetch(now: Date, force: Bool = false) -> Snapshot? {
        lock.lock()
        let cached = cachedSnapshot
        let claimed = lastAttempt
        let tooSoon = !force && (claimed.map { max(0, now.timeIntervalSince($0)) < minimumInterval } ?? false)
        if !tooSoon { lastAttempt = now }
        lock.unlock()

        if tooSoon { return reusableCache(cached, now: now) }
        guard let response = read(), let snapshot = parse(response, fetchedAt: Date()) else { return nil }

        lock.lock(); cachedSnapshot = snapshot; lock.unlock()
        return snapshot
    }

    /// The last snapshot, if it is recent enough and still has a live window.
    private static func reusableCache(_ cached: Snapshot?, now: Date) -> Snapshot? {
        guard let cached, max(0, now.timeIntervalSince(cached.fetchedAt)) <= maxCacheAge else { return nil }
        return live(cached, now: now)
    }

    /// A window whose reset has passed carries a percentage that is certainly
    /// obsolete, so it is dropped rather than shown.
    private static func live(_ window: Window?, now: Date) -> Window? {
        guard let window else { return nil }
        if let reset = window.resetsAt, reset <= now { return nil }
        return window
    }

    private static func live(_ snapshot: Snapshot, now: Date) -> Snapshot? {
        let primary = live(snapshot.primary, now: now)
        let secondary = live(snapshot.secondary, now: now)
        guard primary != nil || secondary != nil else { return nil }
        return Snapshot(
            primary: primary,
            secondary: secondary,
            planType: snapshot.planType,
            fetchedAt: snapshot.fetchedAt
        )
    }

    // MARK: - Transport

    private static func read() -> [String: Any]? {
        guard let executable = codexExecutable() else { return nil }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // Never a pipe nobody reads: startup diagnostics filling it would block
        // the server before it answered anything.
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        let collector = Collector()
        output.fileHandleForReading.readabilityHandler = { handle in
            collector.feed(handle.availableData)
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }

        do { try process.run() } catch { return nil }
        // Terminate on every exit path, escalating if the child ignores SIGTERM,
        // so repeated refreshes can't accumulate server processes.
        defer {
            if process.isRunning {
                process.terminate()
                if exited.wait(timeout: .now() + terminationGrace) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + 1)
                }
            }
        }

        func send(_ object: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
            data.append(0x0A)
            try? input.fileHandleForWriting.write(contentsOf: data)
        }

        send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["clientInfo": ["name": "UsageBar", "version": "1.0"]]
        ])
        // The handshake must complete before any request is answered.
        guard collector.response(id: 1, timeout: handshakeTimeout) != nil else { return nil }
        send(["jsonrpc": "2.0", "method": "initialized", "params": [:]])
        send(["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": [:]])
        return collector.response(id: 2, timeout: responseTimeout)
    }

    /// Resolved the way a shell would, preferring the user-local install.
    private static func codexExecutable() -> URL? {
        let candidates = [
            usageBarHome.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return shellResolved
    }

    /// Other installs (npm, version managers): asked of the login shell once
    /// per launch, since an app doesn't inherit the terminal's PATH.
    private static let shellResolved: URL? = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v codex"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Read on another thread with a deadline: a shell startup that leaves
        // something holding stdout open must not stall refreshes.
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        guard done.wait(timeout: .now() + 5) == .success else {
            if process.isRunning { process.terminate() }
            try? pipe.fileHandleForReading.close()
            return nil
        }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }()

    /// Accumulates stdout, splits it into JSON-RPC messages, and lets a caller
    /// wait for one specific id with a deadline.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var messages: [Int: [String: Any]] = [:]
        private var waiters: [Int: DispatchSemaphore] = [:]

        func feed(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            buffer.append(data)
            var arrived: [(Int, [String: Any])] = []
            while let index = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let id = object["id"] as? Int {
                    arrived.append((id, object))
                }
            }
            for (id, object) in arrived {
                messages[id] = object
                waiters[id]?.signal()
            }
            lock.unlock()
        }

        func response(id: Int, timeout: TimeInterval) -> [String: Any]? {
            lock.lock()
            if let existing = messages[id] {
                lock.unlock()
                return existing
            }
            let semaphore = DispatchSemaphore(value: 0)
            waiters[id] = semaphore
            lock.unlock()

            guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock()
            let result = messages[id]
            lock.unlock()
            return result
        }
    }

    // MARK: - Parse

    private static func parse(_ response: [String: Any], fetchedAt: Date) -> Snapshot? {
        guard let result = response["result"] as? [String: Any],
              let limits = result["rateLimits"] as? [String: Any] else { return nil }
        let primary = window(limits["primary"])
        let secondary = window(limits["secondary"])
        guard primary != nil || secondary != nil else { return nil }
        return Snapshot(
            primary: primary,
            secondary: secondary,
            planType: limits["planType"] as? String,
            fetchedAt: fetchedAt
        )
    }

    private static func window(_ any: Any?) -> Window? {
        guard let dict = any as? [String: Any],
              let used = doubleValue(dict["usedPercent"]) else { return nil }
        return Window(
            usedPercent: used,
            windowMinutes: doubleValue(dict["windowDurationMins"]),
            resetsAt: dateValue(dict["resetsAt"])
        )
    }
}
