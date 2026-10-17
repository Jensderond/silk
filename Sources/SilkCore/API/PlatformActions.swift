import CoreGraphics
import Darwin
import SilkConfig

/// Side effects the core asks the platform to perform. All calls happen on the main thread and must not block;
/// window actions are fire-and-forget (results come back as platform events).
public protocol PlatformActions: AnyObject {
    /// Raises and focuses the window, activating its app.
    func focus(window: WindowID, pid: pid_t)
    /// Presses the window's close button.
    func close(window: WindowID)
    /// Quits the app; returns false when it refuses.
    func terminateApp(pid: pid_t) -> Bool
    func setMinimized(window: WindowID, _ minimized: Bool)
    func setNativeFullscreen(window: WindowID, _ fullscreen: Bool)
    func unhideApp(pid: pid_t)
    /// Runs `/bin/bash -c script` detached with exactly `env` as its environment. Returns false if it couldn't start.
    func execAndForget(_ script: String, env: [String: String]) -> Bool
    /// Warps the mouse pointer.
    func moveMouse(to point: CGPoint)
    var mouseLocation: CGPoint { get }
    /// Running GUI apps the window manager observes.
    func runningApps() -> [AppInfo]
    /// Current output volume; nil if it can't be read.
    func volume() -> VolumeState?
    /// Applies a new output volume, optionally flashing the volume HUD.
    func setVolume(_ state: VolumeState, showHUD: Bool)
    /// Re-reads the config file (`reload-config`).
    func reloadConfig() -> ConfigLoadResult
    /// Sends an event to `subscribe` clients.
    func broadcast(_ event: ServerEvent)
}
