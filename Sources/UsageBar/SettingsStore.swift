import Combine
import Foundation

/// Owns `~/Library/Application Support/UsageBar/settings.json`.
/// Writes are atomic; the file is the only state we persist anywhere.
final class SettingsStore: ObservableObject {
    static let directory = usageBarHome
        .appendingPathComponent("Library/Application Support/UsageBar", isDirectory: true)
    static let fileURL = SettingsStore.directory.appendingPathComponent("settings.json")

    @Published var settings: Settings {
        didSet { save(); onChange?() }
    }

    /// Called after any settings mutation (on the main thread).
    var onChange: (() -> Void)?

    private let writeQueue = DispatchQueue(label: "com.lanes.usagebar.settings-write", qos: .utility)

    init(settings: Settings = Settings()) {
        self.settings = settings
    }

    static func load() -> Settings? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let seconds = try? value.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let text = try value.decode(String.self)
            guard let date = dateValue(text) else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid date")
            }
            return date
        }
        return (try? decoder.decode(Settings.self, from: data))
    }

    func save() {
        let snapshot = settings
        writeQueue.async {
            // Private to this user: settings can hold a DeepSeek token.
            try? FileManager.default.createDirectory(
                at: SettingsStore.directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: SettingsStore.directory.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: SettingsStore.fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: SettingsStore.fileURL.path)
        }
    }
}
