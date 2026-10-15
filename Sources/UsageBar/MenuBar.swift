import AppKit
import Foundation

/// How the status item presents itself (SPEC §12).
enum MenuBarMode: String, Codable, CaseIterable, Identifiable {
    case iconOnly
    case iconAndItems
    case itemsOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iconOnly: return "Icon only"
        case .iconAndItems: return "Icon + items"
        case .itemsOnly: return "Items only"
        }
    }

    var showsIcon: Bool { self != .itemsOnly }
    var showsItems: Bool { self != .iconOnly }
}

/// One selectable value in the menu bar title (SPEC §12).
enum MenuBarItem: String, Codable, CaseIterable, Identifiable {
    case claude5h
    case claudeWeek
    case codex5h
    case codexWeek
    case opencode5h
    case opencodeWeek
    case grok
    case deepseek
    case vpsDays
    case vpsDisk
    case totalSpend

    var id: String { rawValue }

    /// Short label used in labelled mode (SPEC §12).
    var label: String {
        switch self {
        case .claude5h: return "Cl"
        case .claudeWeek: return "Cl·w"
        case .codex5h: return "Cx"
        case .codexWeek: return "Cx·w"
        case .opencode5h: return "OC"
        case .opencodeWeek: return "OC·w"
        case .grok: return "Grok"
        case .deepseek: return "DS"
        case .vpsDays: return "VPS"
        case .vpsDisk: return "Disk"
        case .totalSpend: return "Spend"
        }
    }

    /// Full name shown in the Settings list.
    var title: String {
        switch self {
        case .claude5h: return "Claude 5h"
        case .claudeWeek: return "Claude week"
        case .codex5h: return "Codex 5h"
        case .codexWeek: return "Codex week"
        case .opencode5h: return "OpenCode 5h"
        case .opencodeWeek: return "OpenCode week"
        case .grok: return "Grok"
        case .deepseek: return "DeepSeek"
        case .vpsDays: return "VPS days"
        case .vpsDisk: return "VPS disk"
        case .totalSpend: return "Total spend"
        }
    }

    /// Formatted value. Percent items are % left; a missing value is "–".
    func value(_ values: MenuBarValues) -> String {
        switch self {
        case .claude5h: return percent(values.claude5hLeft)
        case .claudeWeek: return percent(values.claudeWeekLeft)
        case .codex5h: return percent(values.codex5hLeft)
        case .codexWeek: return percent(values.codexWeekLeft)
        case .opencode5h: return percent(values.opencode5hLeft)
        case .opencodeWeek: return percent(values.opencodeWeekLeft)
        case .grok: return percent(values.grokPercentLeft)
        // DeepSeek and the spend total are shown in the display currency (§13).
        case .deepseek: return values.deepseekBalance.map { formatMoney($0) } ?? "–"
        case .totalSpend: return values.totalSpend ?? "–"
        case .vpsDays: return values.vpsDays.map { "\($0)d" } ?? "–"
        case .vpsDisk: return percent(values.vpsDiskUsedPercent)
        }
    }

    private func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        return "\(fmtDecimal(value.rounded(), 0))%"
    }
}

/// Structured values the menu bar title can draw on. Every field is optional:
/// a source that produced nothing simply leaves its slot `nil`.
struct MenuBarValues {
    var claude5hLeft: Double?
    var claudeWeekLeft: Double?
    var codex5hLeft: Double?
    var codexWeekLeft: Double?
    var opencode5hLeft: Double?
    var opencodeWeekLeft: Double?
    var grokPercentLeft: Double?
    /// Balance and spend are in the display currency (SPEC §13).
    var deepseekBalance: Money?
    var deepseekOriginalBalance: Money?
    var totalSpend: String?
    var vpsDays: Int?
    var vpsDiskUsedPercent: Double?
}

/// The exact status-item presentation for a given mode + values. Compared with
/// `==` so the button is only touched when something actually changed (§12).
struct MenuBarDisplay: Equatable {
    var showIcon: Bool
    var title: String
    /// Render the title with an inline 12pt logo per item (SPEC §15).
    var showLogos: Bool = false
    var logoNames: [String?] = []
}

enum MenuBarTitle {
    static let symbolName = "gauge.with.dots.needle.33percent"

    /// Builds the display. Compact: `53% 72%`; labelled: `Cl 53% · Cx 72%`.
    static func display(settings: Settings, values: MenuBarValues) -> MenuBarDisplay {
        let mode = settings.effectiveMenuBarMode
        guard mode.showsItems else { return MenuBarDisplay(showIcon: mode.showsIcon, title: "") }
        let items = settings.effectiveMenuBarItems
        guard !items.isEmpty else { return MenuBarDisplay(showIcon: mode.showsIcon, title: "") }

        let title: String
        if settings.effectiveMenuBarLabelled {
            title = items.map { "\($0.label) \($0.value(values))" }.joined(separator: " · ")
        } else {
            title = items.map { $0.value(values) }.joined(separator: " ")
        }
        return MenuBarDisplay(showIcon: mode.showsIcon, title: title,
                              showLogos: settings.menuBarShowLogos,
                              logoNames: settings.menuBarShowLogos ? items.map { Logos.assetName(for: $0) } : [])
    }

    /// Attributed title with a 12pt service logo in front of each item
    /// (SPEC §15). Items without a logo (e.g. total spend) stay text-only.
    static func attributedTitle(settings: Settings, values: MenuBarValues) -> NSAttributedString {
        let labelled = settings.effectiveMenuBarLabelled
        let separator = labelled ? " · " : " "
        let result = NSMutableAttributedString()
        for (index, item) in settings.effectiveMenuBarItems.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: separator)) }
            if let name = Logos.assetName(for: item),
               let image = Logos.image(named: name)
                ?? NSImage(systemSymbolName: Logos.fallbackSymbol, accessibilityDescription: item.title) {
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = CGRect(x: 0, y: -2, width: 12, height: 12)
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: " "))
            }
            let text = labelled ? "\(item.label) \(item.value(values))" : item.value(values)
            result.append(NSAttributedString(string: text))
        }
        return result
    }

    /// Template SF Symbol for the icon; nil when the symbol is unavailable.
    static func iconImage() -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "UsageBar")
        image?.isTemplate = true
        return image
    }
}
