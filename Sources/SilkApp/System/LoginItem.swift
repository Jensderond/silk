import Foundation
import ServiceManagement

/// Registers Silk as a login item through `SMAppService` (macOS 13+), following the config's
/// `start-at-login` like AeroSpace. Only meaningful for the bundled app.
@MainActor
enum LoginItem {
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
