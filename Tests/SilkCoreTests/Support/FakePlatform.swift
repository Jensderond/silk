import CoreGraphics
import Darwin
import SilkConfig
@testable import SilkCore

/// Records the side effects the core requests.
final class FakePlatform: PlatformActions {
    struct Exec: Equatable {
        let script: String
        let env: [String: String]
    }

    var focused: [WindowID] = []
    var closed: [WindowID] = []
    var terminated: [pid_t] = []
    var terminateSucceeds = true
    var minimized: [(WindowID, Bool)] = []
    var nativeFullscreen: [(WindowID, Bool)] = []
    var unhidden: [pid_t] = []
    var execs: [Exec] = []
    var mouseMoves: [CGPoint] = []
    var mouseLocation: CGPoint = .zero
    var apps: [AppInfo] = []
    var volumeState: VolumeState? = VolumeState(level: 0.5, isMuted: false)
    var volumeHUDShown = false
    var reloadResult: ConfigLoadResult?
    var events: [ServerEvent] = []

    func focus(window: WindowID, pid: pid_t) { focused.append(window) }
    func close(window: WindowID) { closed.append(window) }
    func terminateApp(pid: pid_t) -> Bool {
        terminated.append(pid)
        return terminateSucceeds
    }
    func setMinimized(window: WindowID, _ minimized: Bool) { self.minimized.append((window, minimized)) }
    func setNativeFullscreen(window: WindowID, _ fullscreen: Bool) { nativeFullscreen.append((window, fullscreen)) }
    func unhideApp(pid: pid_t) { unhidden.append(pid) }
    func execAndForget(_ script: String, env: [String: String]) -> Bool {
        execs.append(Exec(script: script, env: env))
        return true
    }
    func moveMouse(to point: CGPoint) {
        mouseMoves.append(point)
        mouseLocation = point
    }
    func runningApps() -> [AppInfo] { apps }
    func volume() -> VolumeState? { volumeState }
    func setVolume(_ state: VolumeState, showHUD: Bool) {
        volumeState = state
        volumeHUDShown = showHUD
    }
    func reloadConfig() -> ConfigLoadResult {
        reloadResult ?? ConfigLoadResult(config: Config(), url: nil, diagnostics: [], isFatal: false)
    }
    func broadcast(_ event: ServerEvent) { events.append(event) }

    var execScripts: [String] { execs.map(\.script) }
}

/// Records delegate notifications.
final class RecordingDelegate: WindowManagerDelegate {
    var activatedModes: [String?] = []
    var reloadedConfigs = 0
    var configMessages: [String?] = []
    var menuBarChanges = 0
    var enabledChanges: [Bool] = []

    func windowManager(_ manager: WindowManager, didActivateMode mode: String?) { activatedModes.append(mode) }
    func windowManager(_ manager: WindowManager, didReloadConfig config: Config) { reloadedConfigs += 1 }
    func windowManager(_ manager: WindowManager, didChangeConfigMessage message: String?) { configMessages.append(message) }
    func windowManagerDidChangeMenuBarState(_ manager: WindowManager) { menuBarChanges += 1 }
    func windowManager(_ manager: WindowManager, didChangeEnabled isEnabled: Bool) { enabledChanges.append(isEnabled) }
}
