import Foundation
import ServiceManagement

/// Registers Silk as a login item through `SMAppService` (macOS 13+). Only meaningful for
/// the bundled app; a bare executable can't be registered.
@MainActor
enum LoginItem {
    /// `SMAppService.status` is a cross-process call (milliseconds); cache it between changes.
    private static var cachedIsEnabled: Bool?

    static var isEnabled: Bool {
        if let cachedIsEnabled { return cachedIsEnabled }
        let enabled = SMAppService.mainApp.status == .enabled
        cachedIsEnabled = enabled
        return enabled
    }

    /// Debug builds share the user's config (`start-at-login = true`) but must never launch at
    /// login next to the real app.
    static var isDebugBuild: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".debug") == true
    }

    /// Applies the desired state, returning a user-presentable error message on failure.
    @discardableResult
    static func set(enabled requested: Bool) -> String? {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return "Launch at login requires running Silk.app"
        }
        let enabled = requested && !isDebugBuild
        let service = SMAppService.mainApp
        defer { cachedIsEnabled = nil }
        do {
            switch (enabled, service.status) {
                case (true, .enabled), (false, .notRegistered), (false, .notFound):
                    return nil
                case (true, _):
                    try service.register()
                case (false, _):
                    try service.unregister()
            }
            return nil
        } catch {
            return "Couldn't \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
        }
    }
}
