import SilkConfig

/// Engine-facing notifications. All methods are called on the main thread, synchronously from within the
/// `WindowManager` call that caused them.
public protocol WindowManagerDelegate: AnyObject {
    /// The active binding mode changed (or was re-activated after a config reload): re-register hotkeys from
    /// `WindowManager.activeBindings`. `mode` is nil while the window manager is disabled.
    func windowManager(_ manager: WindowManager, didActivateMode mode: String?)
    /// A new config was applied by `reload-config`.
    func windowManager(_ manager: WindowManager, didReloadConfig config: Config)
    /// The config error/warning message to show, or nil to dismiss it (AeroSpace's config message window).
    func windowManager(_ manager: WindowManager, didChangeConfigMessage message: String?)
    /// Focused workspace, visible workspaces or mode changed: refresh the menu bar from `menuBarModel()`.
    func windowManagerDidChangeMenuBarState(_ manager: WindowManager)
    /// `enable on|off|toggle` changed the enabled state.
    func windowManager(_ manager: WindowManager, didChangeEnabled isEnabled: Bool)
}

extension WindowManagerDelegate {
    public func windowManager(_ manager: WindowManager, didActivateMode mode: String?) {}
    public func windowManager(_ manager: WindowManager, didReloadConfig config: Config) {}
    public func windowManager(_ manager: WindowManager, didChangeConfigMessage message: String?) {}
    public func windowManagerDidChangeMenuBarState(_ manager: WindowManager) {}
    public func windowManager(_ manager: WindowManager, didChangeEnabled isEnabled: Bool) {}
}
