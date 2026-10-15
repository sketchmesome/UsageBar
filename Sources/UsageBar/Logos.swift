import AppKit

/// Bundled service logos (SPEC §15).
///
/// `Scripts/build_app.sh` copies `Resources/Logos/*.png` into the app bundle's
/// `Contents/Resources/`. Each asset is loaded at most once and cached; when an
/// asset is missing the caller falls back to an SF Symbol.
enum Logos {
    static let fallbackSymbol = "gauge.with.dots.needle.33percent"

    // Asset base names, as bundled (the `@2x` variants are picked up
    // automatically by AppKit).
    static let claude = "logo_claude"
    static let openai = "logo_openai"
    static let opencode = "logo_opencode"
    static let grok = "logo_grok"
    static let deepseek = "logo_deepseek"
    static let ovh = "logo_ovh"

    private static let lock = NSLock()
    private static var cache: [String: NSImage] = [:]
    private static var attempted: Set<String> = []

    /// Loads (and caches) an asset once. Returns nil when it is not bundled.
    static func image(named name: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        if attempted.contains(name) { return nil }
        attempted.insert(name)
        guard let image = load(name) else { return nil }
        cache[name] = image
        return image
    }

    private static func load(_ name: String) -> NSImage? {
        if let image = Bundle.main.image(forResource: name) { return image }
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }

    /// A square copy for inline/attachment use.
    static func resized(_ image: NSImage, to side: CGFloat) -> NSImage {
        let copy = (image.copy() as? NSImage) ?? image
        copy.size = NSSize(width: side, height: side)
        return copy
    }

    // MARK: - Popover rows

    /// Asset base name for a usage row id; nil means "use an SF Symbol".
    static func assetName(forRowID id: String) -> String? {
        switch id {
        case "claude": return claude
        case "codex": return openai
        case "opencode": return opencode
        case "grok": return grok
        case "deepseek": return deepseek
        case "vps": return ovh
        default: return nil
        }
    }

    /// SF Symbol shown when a row has no bundled logo. The Spend row has no
    /// logo by design and uses its own currency symbol (SPEC §15).
    static func rowSymbol(forRowID id: String) -> String {
        switch id {
        case "spend": return "eurosign.circle"
        default: return fallbackSymbol
        }
    }

    // MARK: - Menu bar items (SPEC §15)

    /// Asset base name prefixing a menu bar item, or nil when it has none.
    static func assetName(for item: MenuBarItem) -> String? {
        switch item {
        case .claude5h, .claudeWeek: return claude
        case .codex5h, .codexWeek: return openai
        case .opencode5h, .opencodeWeek: return opencode
        case .grok: return grok
        case .deepseek: return deepseek
        case .vpsDays, .vpsDisk: return ovh
        case .totalSpend: return nil
        }
    }
}
