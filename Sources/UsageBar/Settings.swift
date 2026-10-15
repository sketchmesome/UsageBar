import Foundation

struct Settings: Codable {
    static let defaultConsoleURL = "https://opencode.ai/console"

    // Monthly prices (row 6). `nil` means "not set" — never invented.
    var priceClaude: Double?
    var priceChatGPT: Double?
    var priceOpenCode: Double?
    var priceGrokBot: Double?
    var priceVPS: Double?
    var priceOther: Double?

    // VPS billing (row 7 / SPEC §9).
    var vpsDueDate: Date?
    var vpsBillingPeriod: BillingPeriod = .monthly

    /// Legacy manual conversion rate (non-USD VPS price → USD, §9). Now
    /// superseded by `fxOverrides` + the shared FX rates (SPEC §13); retained
    /// only so older `settings.json` files still decode.
    var vpsCurrencyToUSD: Double?

    // Manual fallbacks.
    var manualGrokPercentLeft: Double?
    var manualClaude5hLeft: Double?
    var manualClaudeWeekLeft: Double?
    var manualDeepseekBalance: Double?

    // DeepSeek endpoint + token.
    var deepseekEndpointURL: String?
    var deepseekToken: String?

    // OpenCode console + cap.
    var opencodeConsoleURL: String = Settings.defaultConsoleURL
    var opencodeMonthlyCap: Double? = 80

    // OpenCode console reload interval, minutes, clamped 15...240 (SPEC §10).
    // Other sources keep using `refreshIntervalMinutes`.
    var opencodeRefreshMinutes: Int = 60

    // Refresh interval, minutes, clamped 5...30.
    var refreshIntervalMinutes: Int = 10

    // Launch at login (SPEC §11).
    var launchAtLogin: Bool = true

    // Menu bar display (SPEC §12).
    var menuBarMode: MenuBarMode = .iconAndItems
    var menuBarItems: [MenuBarItem] = [.claude5h, .codex5h]
    var menuBarLabelled: Bool = false
    /// Prefix each menu bar item with its 12pt service logo (SPEC §15).
    var menuBarShowLogos: Bool = false
    /// Set true once the user edits the menu bar items/mode/labels in Settings
    /// (SPEC §16). While false, the new default presentation applies.
    var menuBarCustomized: Bool = false

    // Display currency (SPEC §13). Every money value is shown in
    // `displayCurrency`; entered prices start in `priceCurrency`.
    var displayCurrency: String = "EUR"
    var priceCurrency: String = "USD"
    /// Manual rates keyed "USD->EUR", "GBP->EUR", … (blank = auto).
    var fxOverrides: [String: Double] = [:]
    /// When true, the manual OpenCode cap wins over live console values.
    var opencodeOverride: Bool = false

    init() {}

    /// Currencies the pickers offer.
    static let supportedCurrencies = ["EUR", "USD", "GBP"]

    var effectiveConsoleURL: String {
        let trimmed = opencodeConsoleURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Settings.defaultConsoleURL : trimmed
    }

    var clampedRefreshMinutes: Int {
        min(30, max(5, refreshIntervalMinutes))
    }

    var clampedOpenCodeRefreshMinutes: Int {
        min(240, max(15, opencodeRefreshMinutes))
    }

    /// Display currency, validated against the offered set (default EUR).
    var effectiveDisplayCurrency: String {
        let code = displayCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return Settings.supportedCurrencies.contains(code) ? code : "EUR"
    }

    /// Currency that entered prices are in, validated (default USD).
    var effectivePriceCurrency: String {
        let code = priceCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return Settings.supportedCurrencies.contains(code) ? code : "USD"
    }

    var effectiveMonthlyCap: Double {
        let cap = opencodeMonthlyCap ?? 80
        return cap > 0 ? cap : 80
    }

    // MARK: - Menu bar defaults (SPEC §16)

    /// Effective menu bar presentation. Until the user has explicitly customised
    /// the menu bar in Settings, the §16 defaults apply: icon + items, the
    /// Claude/Codex pair, and short labels ("Cl 98% · Cx 72%").
    var effectiveMenuBarMode: MenuBarMode {
        menuBarCustomized ? menuBarMode : .iconAndItems
    }

    var effectiveMenuBarItems: [MenuBarItem] {
        menuBarCustomized ? menuBarItems : [.claude5h, .codex5h]
    }

    var effectiveMenuBarLabelled: Bool {
        menuBarCustomized ? menuBarLabelled : true
    }

    mutating func customizeMenuBar() {
        guard !menuBarCustomized else { return }
        menuBarMode = effectiveMenuBarMode
        menuBarItems = effectiveMenuBarItems
        menuBarLabelled = effectiveMenuBarLabelled
        menuBarCustomized = true
    }

    // MARK: - Codable with defaults

    enum CodingKeys: String, CodingKey {
        case priceClaude, priceChatGPT, priceOpenCode, priceGrokBot, priceVPS, priceOther
        case vpsDueDate, vpsBillingPeriod, vpsCurrencyToUSD
        case manualGrokPercentLeft, manualClaude5hLeft, manualClaudeWeekLeft, manualDeepseekBalance
        case deepseekEndpointURL, deepseekToken
        case opencodeConsoleURL, opencodeMonthlyCap, opencodeRefreshMinutes
        case refreshIntervalMinutes
        case launchAtLogin, menuBarMode, menuBarItems, menuBarLabelled, menuBarShowLogos
        case menuBarCustomized
        case displayCurrency, priceCurrency, fxOverrides, opencodeOverride
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        priceClaude = c.decodeOrNil(Double.self, .priceClaude)
        priceChatGPT = c.decodeOrNil(Double.self, .priceChatGPT)
        priceOpenCode = c.decodeOrNil(Double.self, .priceOpenCode)
        priceGrokBot = c.decodeOrNil(Double.self, .priceGrokBot)
        priceVPS = c.decodeOrNil(Double.self, .priceVPS)
        priceOther = c.decodeOrNil(Double.self, .priceOther)

        vpsDueDate = c.decodeOrNil(Date.self, .vpsDueDate)
        vpsBillingPeriod = c.decodeOr(BillingPeriod.self, .vpsBillingPeriod, .monthly)
        vpsCurrencyToUSD = c.decodeOrNil(Double.self, .vpsCurrencyToUSD)

        manualGrokPercentLeft = c.decodeOrNil(Double.self, .manualGrokPercentLeft)
        manualClaude5hLeft = c.decodeOrNil(Double.self, .manualClaude5hLeft)
        manualClaudeWeekLeft = c.decodeOrNil(Double.self, .manualClaudeWeekLeft)
        manualDeepseekBalance = c.decodeOrNil(Double.self, .manualDeepseekBalance)

        deepseekEndpointURL = c.decodeOrNil(String.self, .deepseekEndpointURL)
        deepseekToken = c.decodeOrNil(String.self, .deepseekToken)

        opencodeConsoleURL = c.decodeOr(String.self, .opencodeConsoleURL, Settings.defaultConsoleURL)
        opencodeMonthlyCap = c.decodeOr(Double.self, .opencodeMonthlyCap, 80)
        opencodeRefreshMinutes = c.decodeOr(Int.self, .opencodeRefreshMinutes, 60)
        refreshIntervalMinutes = c.decodeOr(Int.self, .refreshIntervalMinutes, 10)

        launchAtLogin = c.decodeOr(Bool.self, .launchAtLogin, true)
        menuBarMode = c.decodeOr(MenuBarMode.self, .menuBarMode, .iconAndItems)
        menuBarItems = c.decodeOr([MenuBarItem].self, .menuBarItems, [.claude5h, .codex5h])
        menuBarLabelled = c.decodeOr(Bool.self, .menuBarLabelled, false)
        menuBarShowLogos = c.decodeOr(Bool.self, .menuBarShowLogos, false)
        menuBarCustomized = c.decodeOr(Bool.self, .menuBarCustomized, false)

        displayCurrency = c.decodeOr(String.self, .displayCurrency, "EUR")
        priceCurrency = c.decodeOr(String.self, .priceCurrency, "USD")
        fxOverrides = c.decodeOr([String: Double].self, .fxOverrides, [:])
        opencodeOverride = c.decodeOr(Bool.self, .opencodeOverride, false)
    }
}

private extension KeyedDecodingContainer {
    func decodeOrNil<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        guard let value = try? decodeIfPresent(type, forKey: key) else { return nil }
        return value
    }

    func decodeOr<T: Decodable>(_ type: T.Type, _ key: Key, _ fallback: T) -> T {
        decodeOrNil(type, key) ?? fallback
    }
}
