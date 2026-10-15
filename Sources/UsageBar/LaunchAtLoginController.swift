import Foundation
import ServiceManagement

/// SPEC §11 — "Launch at login" via `SMAppService.mainApp`.
///
/// On launch and on every toggle we reconcile the service with the setting.
/// Registration only happens for a bundle inside `/Applications`; a debug
/// binary run from a build directory reports how to enable it instead.
final class LaunchAtLoginController: ObservableObject {
    /// Human-readable status/error text shown beneath the toggle.
    @Published private(set) var statusText = ""

    /// True only when this process is an app bundle in `/Applications`.
    static var isInstalledInApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    private var service: SMAppService { .mainApp }

    /// Reconciles the login item with `enabled`, returning the status text.
    /// Safe to call repeatedly; it only registers/unregisters on a change.
    @discardableResult
    func apply(enabled: Bool) -> String {
        guard !enabled || Self.isInstalledInApplications else {
            statusText = "Install to /Applications to enable"
            return statusText
        }
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            statusText = Self.describe(service.status)
        } catch {
            statusText = "Could not update: \(error.localizedDescription)"
        }
        return statusText
    }

    /// Refreshes the status text without touching the service (e.g. on open).
    func refresh() {
        guard Self.isInstalledInApplications else {
            statusText = "Install to /Applications to enable"
            return
        }
        statusText = Self.describe(service.status)
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "Enabled"
        case .notRegistered: return "Not enabled"
        case .requiresApproval: return "Approve in System Settings › Login Items"
        case .notFound: return "Register the app to enable"
        default: return "Unknown status"
        }
    }
}
