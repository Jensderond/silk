import Foundation
import ServiceManagement

/// Registers Silk as a login item through `SMAppService` (macOS 13+). Only meaningful for
/// the bundled app; a bare executable can't be registered.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Applies the desired state, returning a user-presentable error message on failure.
    @discardableResult
    static func set(enabled: Bool) -> String? {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return "Launch at login requires running Silk.app"
        }
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
