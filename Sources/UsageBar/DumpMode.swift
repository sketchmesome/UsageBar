import UserNotifications
import AppKit
import Foundation

/// Headless `--dump` mode: runs exactly one refresh of every source through the
/// shared `UsageEngine`, prints one line per row to stdout, then exits.
///
/// No UI and no status item are created. Settings secrets (the DeepSeek token)
/// are never printed.
enum DumpMode {
    /// Carries the engine result across threads.
    private final class ResultBox {
        private let lock = NSLock()
        private var stored: RefreshResult?
        private var finished = false

        func store(_ result: RefreshResult) {
            lock.lock()
            stored = result
            finished = true
            lock.unlock()
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        var result: RefreshResult? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// Runs one full refresh, prints the rows, and exits 0. Never returns.
    static func run() -> Never {
        // WebKit needs a launched application and a spinning main run loop; the
        // accessory policy keeps this headless (no Dock icon, no windows).
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let settings = SettingsStore.load() ?? Settings()
        let box = ResultBox()

        // The engine must run off the main thread: the OpenCode source blocks
        // on a main-queue webview scrape, so the main run loop has to stay free.
        DispatchQueue.global(qos: .utility).async {
            // A diagnostic should show live values, so it asks every source for
            // fresh data rather than reusing anything cached in-process.
            let result = UsageEngine().refresh(settings: settings, now: Date(), forceLive: true)
            box.store(result)
        }

        while !box.isFinished {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        for row in box.result?.rows ?? [] {
            print(line(for: row, settings: settings, now: Date()))
        }

        if let result = box.result {
            print(vpsStatsLine(result: result, settings: settings, now: Date()))
            print(fxLine(result: result))
            print(menuBarLine(result: result, settings: settings))
            if let pace = result.opencodePace {
                let usual = pace.usualPerHour.map { "$\(fmtDecimal($0, 2))/h" } ?? "learning"
                print("Pace | OpenCode $\(fmtDecimal(pace.recentPerHour, 2))/h last 30 min | usual \(usual)")
            }
        }

        print(notificationLine())
        exit(0)
    }

    /// Whether macOS will actually show UsageBar's alerts.
    private static func notificationLine() -> String {
        var status = "unknown"
        var detail = ""
        let done = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized: status = "allowed"
            case .provisional: status = "provisional (delivered quietly)"
            case .denied: status = "DENIED — turn on in System Settings → Notifications → UsageBar"
            case .notDetermined: status = "not asked yet"
            case .ephemeral: status = "ephemeral"
            @unknown default: status = "unknown"
            }
            detail = "banners \(settings.alertSetting == .enabled ? "on" : "off") · sound \(settings.soundSetting == .enabled ? "on" : "off")"
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        var delivered: [String] = []
        let listed = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getDeliveredNotifications { notes in
            delivered = notes.prefix(5).map { "\($0.request.content.title) (\(relativeAge($0.date, now: Date())))" }
            listed.signal()
        }
        _ = listed.wait(timeout: .now() + 5)
        let recent = delivered.isEmpty ? "none in Notification Center" : delivered.joined(separator: " · ")
        return "Notifications | \(status) | \(detail) | \(recent)"
    }

    /// `TITLE | value | source tag | footnote`, with any settings secret
    /// redacted and a trailing `STALE` marker when the row is past its
    /// freshness budget (SPEC §17).
    static func line(for row: UsageRow, settings: Settings, now: Date = Date()) -> String {
        let footnote = row.footnote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var raw = "\(row.title) | \(row.value) | \(row.tag.rawValue) | \(footnote)"
        if row.isStale(now: now) { raw += " | STALE" }
        return redacted(raw, settings: settings)
    }

    /// Extra diagnostic line for the VPS telemetry (disk/RAM/load/uptime),
    /// which the popover renders in its VPS section rather than as a row.
    static func vpsStatsLine(result: RefreshResult, settings: Settings, now: Date) -> String {
        let parts = [
            ("Disk", result.vps?.diskLine),
            ("RAM", result.vps?.ramLine),
            ("Load", result.vps?.loadLine),
            ("Uptime", result.vps?.uptimeLine)
        ].compactMap { label, value in value.map { "\(label) \($0)" } }

        let value: String
        let tag: SourceTag
        if !parts.isEmpty {
            value = parts.joined(separator: " · ")
            tag = .live
        } else if !result.vpsConfigured {
            value = "endpoint not configured"
            tag = .none
        } else {
            value = result.vpsNote ?? "no VPS data"
            tag = .none
        }

        var footnote: [String] = []
        if let cached = result.vps?.cachedAt {
            footnote.append("cached \(relativeAge(cached, now: now))")
        }
        if result.billing?.stale == true { footnote.append("stale") }

        let row = UsageRow(
            id: "vps-stats",
            title: "VPS stats",
            value: value,
            footnote: footnote.isEmpty ? nil : footnote.joined(separator: " · "),
            tag: tag,
            updated: result.vps?.cachedAt
        )
        return line(for: row, settings: settings)
    }

    /// The computed status-item title (`Menu bar | <title>`), per SPEC §12.
    static func menuBarLine(result: RefreshResult, settings: Settings) -> String {
        let display = MenuBarTitle.display(settings: settings, values: result.menuBarValues)
        return redacted("Menu bar | \(display.title)", settings: settings)
    }

    /// Diagnostic line for the FX rates used this refresh (SPEC §13): source,
    /// quote date, and the per-EUR rates for the currencies we care about.
    static func fxLine(result: RefreshResult) -> String {
        let fx = result.fx
        guard let rates = fx.rates else {
            return "FX | \(fx.displayCurrency) | no rates (manual overrides only)"
        }
        let wanted = ["USD", "GBP", "EUR"].map { code -> String in
            guard let rate = fx.perEUR(code) else { return "\(code) –" }
            return "\(code) \(fmtDecimal(rate, 4))"
        }
        return "FX | \(fx.displayCurrency) | \(rates.source) \(rates.date) | \(wanted.joined(separator: " · "))"
    }

    /// Defensive: strip the configured DeepSeek token if it ever leaks into a
    /// row. Rows never carry it today, but the token must never reach stdout.
    private static func redacted(_ text: String, settings: Settings) -> String {
        guard let token = settings.deepseekToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return text }
        // Remove rather than replace: even the redaction marker could be a
        // configured token. Repeat in case removal joins another occurrence.
        var result = text
        while result.range(of: token, options: .literal) != nil {
            result = result.replacingOccurrences(of: token, with: "", options: .literal)
        }
        return result
    }
}
