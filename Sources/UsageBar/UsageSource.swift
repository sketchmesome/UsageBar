import Foundation

/// A single usage row provider. Implementations do all file/network work on the
/// caller's (non-main) thread and return one finished row.
protocol UsageSource {
    var id: String { get }
    func makeRow(settings: Settings, now: Date) -> UsageRow
}
