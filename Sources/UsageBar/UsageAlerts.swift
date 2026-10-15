import Foundation
import UserNotifications

/// macOS notifications when a usage window runs low or is burning fast.
///
/// Fed once per refresh with the same "% left" values the menu bar shows, so it
/// adds no timers or I/O of its own. Two kinds of alert, each sent once:
/// - a threshold alert when a window falls to 25%, 10% or 0% left (re-armed
///   once the window recovers, i.e. after a reset);
/// - a burn alert when the recent rate of use would empty the window within
///   the hour (at most one per window every 30 minutes).
/// The first evaluation after launch only records state, so restarting the app
/// never replays alerts for windows that were already low.
final class UsageAlerts {
    private struct Window {
        let key: String
        let name: String
        /// The popover row this value comes from, for its timestamp.
        let source: String
        let left: Double?
    }

    /// When a source's value was actually observed, and whether it is stale.
    struct Observation {
        var at: Date?
        var stale: Bool
        /// Read from the service (LIVE/EST), not typed in by hand. Only
        /// measured values feed burn rates.
        var measured: Bool
    }

    static let thresholds: [Double] = [25, 10, 0]
    /// A window must climb this far back above a threshold to re-arm it.
    private static let rearmMargin: Double = 5
    private static let historySpan: TimeInterval = 45 * 60
    private static let minimumBurnSpan: TimeInterval = 10 * 60
    private static let minimumBurnDrop: Double = 5
    private static let burnHorizonMinutes: Double = 60
    private static let burnCooldown: TimeInterval = 30 * 60

    private var seeded = false
    private var notified: [String: Set<Double>] = [:]
    private var history: [String: [(at: Date, left: Double)]] = [:]
    private var lastBurnAlert: [String: Date] = [:]

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// - Parameter observations: per popover row id ("claude", "codex", …),
    ///   when its value was read. Burn rates use these times, so a reading that
    ///   is merely reused is never mistaken for new consumption.
    func evaluate(values: MenuBarValues, observations: [String: Observation], now: Date, enabled: Bool) {
        let windows = [
            Window(key: "claude5h", name: "Claude 5h", source: "claude", left: values.claude5hLeft),
            Window(key: "claudeWeek", name: "Claude week", source: "claude", left: values.claudeWeekLeft),
            Window(key: "codex5h", name: "Codex 5h", source: "codex", left: values.codex5hLeft),
            Window(key: "codexWeek", name: "Codex week", source: "codex", left: values.codexWeekLeft),
            Window(key: "opencode5h", name: "OpenCode 5h", source: "opencode", left: values.opencode5hLeft),
            Window(key: "opencodeWeek", name: "OpenCode week", source: "opencode", left: values.opencodeWeekLeft),
            Window(key: "grok", name: "Grok Bot", source: "grok", left: values.grokPercentLeft)
        ]
        let announce = enabled && seeded
        for window in windows {
            guard let left = window.left else { continue }
            let observation = observations[window.source]
            checkThresholds(window, left: left, announce: announce)
            if let observation, observation.measured, !observation.stale {
                checkBurn(window, left: left, at: observation.at ?? now, now: now, announce: announce)
            }
        }
        seeded = true
    }

    private func checkThresholds(_ window: Window, left: Double, announce: Bool) {
        var sent = notified[window.key] ?? []
        sent = sent.filter { left <= $0 + Self.rearmMargin }
        let crossed = Self.thresholds.filter { left <= $0 && !sent.contains($0) }
        if let lowest = crossed.min() {
            // Mark every threshold at or above the lowest crossed one, so a drop
            // straight from 30% to 8% sends one alert, not two.
            sent.formUnion(Self.thresholds.filter { $0 >= lowest })
            if announce {
                let body = lowest == 0
                    ? "\(window.name) is used up."
                    : "\(window.name): \(Int(left.rounded()))% left."
                post(id: "\(window.key)-\(Int(lowest))", title: "Usage low", body: body)
            }
        }
        notified[window.key] = sent
    }

    private func checkBurn(_ window: Window, left: Double, at observedAt: Date, now: Date, announce: Bool) {
        var samples = history[window.key] ?? []
        // The same observation seen again (a cached or reused reading) adds nothing.
        if let last = samples.last, observedAt <= last.at { return }
        // A jump back up is a window reset; earlier samples no longer apply.
        if let last = samples.last, left > last.left + Self.rearmMargin { samples.removeAll() }
        samples.append((observedAt, left))
        samples.removeAll { now.timeIntervalSince($0.at) > Self.historySpan }
        history[window.key] = samples

        guard announce, left > 0, let oldest = samples.first else { return }
        let span = observedAt.timeIntervalSince(oldest.at)
        let drop = oldest.left - left
        guard span >= Self.minimumBurnSpan, drop >= Self.minimumBurnDrop else { return }
        let perMinute = drop / (span / 60)
        let minutesToEmpty = left / perMinute
        guard minutesToEmpty <= Self.burnHorizonMinutes else { return }
        if let last = lastBurnAlert[window.key], now.timeIntervalSince(last) < Self.burnCooldown { return }
        lastBurnAlert[window.key] = now
        post(
            id: "\(window.key)-burn",
            title: "Burning fast",
            body: "\(window.name): down \(Int(drop.rounded()))% in \(Int((span / 60).rounded())) min — at this pace it's empty in ~\(max(1, Int(minutesToEmpty.rounded()))) min."
        )
    }

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "\(id)-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
