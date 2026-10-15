import AppKit
import SwiftUI

final class AppController: NSObject, NSPopoverDelegate {
    private let store = SettingsStore()
    private let engine = UsageEngine()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    private var settingsWindow: NSWindow?
    private let loginController = OpenCodeLoginController()
    private let launchAtLogin = LaunchAtLoginController()
    private let alerts = UsageAlerts()
    private let trends = Trends()
    /// "+0.40 GB/day · fills in ~58 days", from the last refresh.
    private var lastDiskTrend: String?

    private var timer: Timer?
    private var timerMinutes: Int?
    private var updatingDueDate = false
    private var lastRefresh: Date?
    private var rows: [UsageRow] = []
    private var lastVPS: VPSStatus?
    private var lastBilling: VPSBilling?
    private var lastVPSConfigured = false
    private var lastVPSNote: String?
    /// FX context and live plan values from the last refresh (SPEC §13), reused
    /// when settings change between refreshes.
    private var lastFX = FX.make(settings: Settings(), rates: nil)
    private var lastLive = LivePlanValues()

    // Menu bar title state (SPEC §12): only reassign the button when the
    // computed display actually changes.
    private var menuBarValues = MenuBarValues()
    private var lastMenuBarDisplay: MenuBarDisplay?
    private var appliedLaunchAtLogin: Bool?

    private let workQueue = DispatchQueue(label: "com.lanes.usagebar.refresh", qos: .utility)
    private var refreshing = false
    private var pendingOpenCodeRefresh = false

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        applyMenuBar()
        // A fresh sign-in shows straight away rather than at the next reload.
        loginController.onClose = { [weak self] in
            self?.refresh(force: true, reloadOpenCode: true, live: true)
        }

        popover.animates = false
        popover.behavior = .transient
        popover.delegate = self

        store.onChange = { [weak self] in
            guard let self, !self.updatingDueDate else { return }
            self.scheduleTimer()
            self.advanceVPSIfNeededAndRefreshUI()
            self.syncLaunchAtLogin()
            self.applyMenuBar()
            self.requestAlertPermissionIfNeeded()
        }

        // Refresh on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        workQueue.async { [weak self] in
            let settings = SettingsStore.load() ?? Settings()
            DispatchQueue.main.async {
                guard let self else { return }
                self.store.settings = settings
                self.requestAlertPermissionIfNeeded()
                self.scheduleTimer()
                self.refresh(force: true)
            }
        }
    }

    // MARK: - Timer

    private func scheduleTimer() {
        let minutes = store.settings.clampedRefreshMinutes
        guard timerMinutes != minutes else { return }
        timer?.invalidate()
        timerMinutes = minutes
        let interval = TimeInterval(minutes * 60)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh(force: true)
        }
        timer.tolerance = min(120, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Asks for notification permission once, and only while alerts are on.
    private var requestedAlertPermission = false
    private func requestAlertPermissionIfNeeded() {
        guard store.settings.usageAlerts, !requestedAlertPermission else { return }
        requestedAlertPermission = true
        alerts.requestPermission()
    }

    @objc private func systemDidWake() {
        refresh(force: true)
    }

    // MARK: - Refresh

    /// Debounced: skips when the last refresh finished less than 60 s ago
    /// unless `force` is set. `reloadOpenCode` is only set by an explicit
    /// popover "Refresh" click so the console webview obeys its own interval
    /// otherwise (SPEC §10).
    private func refresh(force: Bool, reloadOpenCode: Bool = false, live: Bool = false) {
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        guard !refreshing else {
            if reloadOpenCode { pendingOpenCodeRefresh = true }
            return
        }
        refreshing = true

        advanceVPSIfNeededAndRefreshUI(repaint: false)
        let settings = store.settings
        let now = Date()

        workQueue.async { [weak self] in
            guard let self else { return }
            let result = self.engine.refresh(
                settings: settings,
                now: now,
                forceOpenCode: reloadOpenCode,
                forceLive: live
            )
            DispatchQueue.main.async {
                self.refreshing = false
                self.apply(result, now: now)
                if self.pendingOpenCodeRefresh {
                    self.pendingOpenCodeRefresh = false
                    self.refresh(force: true, reloadOpenCode: true, live: true)
                }
            }
        }
    }

    private func apply(_ result: RefreshResult, now: Date) {
        rows = result.rows
        lastRefresh = Date()
        lastVPS = result.vps
        lastBilling = result.billing
        lastVPSConfigured = result.vpsConfigured
        lastVPSNote = result.vpsNote
        lastFX = result.fx
        lastLive = result.live
        menuBarValues = result.menuBarValues
        var observations: [String: UsageAlerts.Observation] = [:]
        for row in result.rows {
            observations[row.id] = UsageAlerts.Observation(
                at: row.updated,
                stale: row.isStale(now: now),
                measured: row.tag == .live || row.tag == .estimated
            )
        }
        let paceNotes = alerts.evaluate(values: result.menuBarValues, observations: observations,
                                        opencodePace: result.opencodePace,
                                        interval: TimeInterval(store.settings.clampedRefreshMinutes * 60),
                                        now: now, enabled: store.settings.usageAlerts)
        // Weekly daily burn, for measured (LIVE/EST) rows only.
        let v = result.menuBarValues
        let burnNotes: [String: String?] = [
            "claude": WeeklyBurn.note(left: v.claudeWeekLeft, reset: v.claudeWeekReset, now: now),
            "codex": WeeklyBurn.note(left: v.codexWeekLeft, reset: v.codexWeekReset, now: now),
            "opencode": WeeklyBurn.note(left: v.opencodeWeekLeft, reset: v.opencodeWeekReset, now: now),
            "grok": WeeklyBurn.note(left: v.grokPercentLeft, reset: v.grokReset, now: now)
        ]
        for index in rows.indices {
            let id = rows[index].id
            let fresh = observations[id].map { $0.measured && !$0.stale } ?? false
            let burn = fresh ? burnNotes[id] ?? nil : nil
            let extra = [paceNotes[id], burn].compactMap { $0 }
            guard !extra.isEmpty else { continue }
            // Pace and burn get their own line under the row's details.
            rows[index].footnote = [rows[index].footnote, extra.joined(separator: " · ")]
                .compactMap { $0 }.joined(separator: "\n")
        }

        // Days-long trends: DeepSeek runway and VPS disk growth.
        let deepseekLive = rows.first { $0.id == "deepseek" }?.tag == .live
        let trendNotes = trends.update(
            balance: deepseekLive ? result.menuBarValues.deepseekOriginalBalance : nil,
            disk: result.vps.flatMap { vps in
                vps.diskUsedGB.map { (used: $0, free: vps.diskFreeGB, at: vps.cachedAt ?? now) }
            },
            now: now,
            enabled: store.settings.usageAlerts
        )
        if let note = trendNotes.deepseek, let index = rows.firstIndex(where: { $0.id == "deepseek" }) {
            rows[index].footnote = [rows[index].footnote, note].compactMap { $0 }.joined(separator: " · ")
        }
        lastDiskTrend = trendNotes.disk

        // Settings may have changed during the scrape; never overwrite a newer due date.
        advanceVPSIfNeededAndRefreshUI(repaint: false)
        applyMenuBar()

        if popover.isShown {
            renderPopoverContent()
        }
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        renderPopoverContent()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        refresh(force: false)
    }

    private func renderPopoverContent() {
        let view = PopoverView(
            rows: rows,
            lastRefresh: lastRefresh,
            now: Date(),
            vps: lastVPS,
            vpsConfigured: lastVPSConfigured,
            vpsNote: lastVPSNote,
            vpsSummary: VPSSummary.make(settings: store.settings, billing: lastBilling, fx: lastFX),
            diskTrend: lastDiskTrend,
            rowOrder: store.settings.effectiveMenuBarItems.compactMap(\.rowID),
            onRefresh: { [weak self] in self?.refresh(force: true, reloadOpenCode: true, live: true) },
            onSettings: { [weak self] in self?.showSettings() },
            onSignIn: { [weak self] in
                self?.loginController.show(urlString: self?.store.settings.effectiveConsoleURL ?? Settings.defaultConsoleURL)
            },
            onQuit: { NSApp.terminate(nil) }
        )
        // While open, update the existing view in place: rebuilding it on every
        // refresh reset the scroll position and made the popover jump.
        let controller: NSHostingController<PopoverView>
        if let existing = popover.contentViewController as? NSHostingController<PopoverView> {
            existing.rootView = view
            controller = existing
        } else {
            controller = NSHostingController(rootView: view)
            popover.contentViewController = controller
        }
        controller.view.layoutSubtreeIfNeeded()
        let fitting = controller.view.fittingSize
        let size = NSSize(
            width: max(448, fitting.width),
            height: max(360, min(560, fitting.height))
        )
        if abs(popover.contentSize.width - size.width) > 1 || abs(popover.contentSize.height - size.height) > 1 {
            popover.contentSize = size
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // Destroy the hosted view so nothing renders while the popover is closed.
        popover.contentViewController = nil
    }

    // MARK: - Settings window

    private func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(store: store, launchAtLogin: launchAtLogin))
        let window = NSWindow(contentViewController: hosting)
        window.title = "UsageBar Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - VPS catch-up

    /// Advances the stored due date on settings changes too, then repaints.
    private func advanceVPSIfNeededAndRefreshUI(repaint: Bool = true) {
        lastFX = FX.make(settings: store.settings, rates: lastFX.rates)
        if let index = rows.firstIndex(where: { $0.id == "deepseek" }) {
            if rows[index].tag == .live, let original = menuBarValues.deepseekOriginalBalance {
                // Shown in its own currency, so nothing to redo — and rewriting
                // the row here would drop its pace/runway notes.
                menuBarValues.deepseekBalance = original
            } else {
                rows[index] = DeepSeekSource().manualRow(settings: store.settings, fx: lastFX, note: nil)
            }
        }
        let outcome = VPSDueSource().evaluate(
            settings: store.settings,
            now: Date(),
            billing: lastBilling,
            fx: lastFX
        )
        if let due = outcome.updatedDueDate, store.settings.vpsDueDate != due {
            updatingDueDate = true
            store.settings.vpsDueDate = due
            updatingDueDate = false
        }
        menuBarValues.vpsDays = outcome.days
        if let index = rows.firstIndex(where: { $0.id == "vps" }) { rows[index] = outcome.row }
        if let index = rows.firstIndex(where: { $0.id == "spend" }) {
            let spendOutcome = SpendSource().makeRow(
                settings: store.settings,
                fx: lastFX,
                billing: lastBilling,
                live: lastLive
            )
            rows[index] = spendOutcome.row
            menuBarValues.totalSpend = spendOutcome.total
        }
        if repaint, popover.isShown { renderPopoverContent() }
    }

    // MARK: - Launch at login (SPEC §11)

    /// Applies `settings.launchAtLogin` to `SMAppService.mainApp` when it
    /// changed. Called at launch (via the first settings load) and on toggles.
    private func syncLaunchAtLogin() {
        let desired = store.settings.launchAtLogin
        guard appliedLaunchAtLogin != desired else { return }
        appliedLaunchAtLogin = desired
        launchAtLogin.apply(enabled: desired)
    }

    // MARK: - Menu bar title (SPEC §12)

    /// Recomputes the title/icon and only assigns to the button when the
    /// presentation actually changed.
    private func applyMenuBar() {
        // Keep live readings, but resolve manual fallbacks from current settings
        // even when an older refresh is still in flight.
        var values = menuBarValues
        if rows.first(where: { $0.id == "claude" })?.tag != .live {
            values.claude5hLeft = store.settings.manualClaude5hLeft
            values.claudeWeekLeft = store.settings.manualClaudeWeekLeft
        }
        if rows.first(where: { $0.id == "grok" })?.tag != .live {
            values.grokPercentLeft = store.settings.manualGrokPercentLeft
        }
        if rows.first(where: { $0.id == "deepseek" })?.tag != .live {
            values.deepseekBalance = store.settings.manualDeepseekBalance.map { Money($0, "USD") }
        }
        let display = MenuBarTitle.display(settings: store.settings, values: values)
        guard display != lastMenuBarDisplay else { return }

        guard let button = statusItem.button else { return }
        if display.showIcon != lastMenuBarDisplay?.showIcon {
            button.image = display.showIcon ? MenuBarTitle.iconImage() : nil
            button.imagePosition = display.showIcon ? .imageLeading : .noImage
        }
        // Assigning `title` clears any attributed title and vice versa, so the
        // two paths stay mutually exclusive (SPEC §15).
        if display.title != lastMenuBarDisplay?.title
            || display.showLogos != lastMenuBarDisplay?.showLogos
            || display.logoNames != lastMenuBarDisplay?.logoNames
            || display.tints != lastMenuBarDisplay?.tints {
            // Always attributed, so low values can be tinted (logos optional);
            // empty when the mode hides the items.
            button.attributedTitle = display.title.isEmpty
                ? NSAttributedString(string: "")
                : MenuBarTitle.attributedTitle(settings: store.settings, values: values, logos: display.showLogos)
        }
        lastMenuBarDisplay = display
    }
}
