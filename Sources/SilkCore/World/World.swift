import CoreGraphics
import Foundation
import SilkConfig

/// Receives the world's engine-facing notifications (implemented by `WindowManager`).
protocol WorldObserver: AnyObject {
    func worldDidActivateMode(_ mode: String?)
    func worldDidReloadConfig(_ config: Config)
    func worldDidChangeConfigMessage(_ message: String?)
    func worldDidChangeEnabled(_ isEnabled: Bool)
}

/// All window-manager state: the trees, workspace↔monitor mapping, focus, mode and config. Main thread only.
///
/// This is AeroSpace's global state gathered into one object. Commands, callbacks and platform events all
/// operate on it; `WindowManager` is the public facade.
final class World {
    let platform: PlatformActions
    weak var observer: WorldObserver?
    let processEnvironment: [String: String]
    let now: () -> Date
    let regexes = RegexCache()

    private(set) var config: Config
    private(set) var compiledConfig: CompiledConfig
    var configURL: URL?

    /// Connected monitors in `NSScreen.screens` order.
    private(set) var monitors: [Monitor]
    /// Frames of every monitor ever seen, so workspaces of a disconnected monitor land on the nearest one.
    var lastKnownMonitorFrames: [MonitorID: CGRect] = [:]

    var workspacesByName: [String: Workspace] = [:]
    var visibleWorkspaceByMonitor: [MonitorID: Workspace] = [:]
    var monitorOfVisibleWorkspace: [String: MonitorID] = [:]
    var prevVisibleWorkspaceByMonitor: [MonitorID: String] = [:]

    var windowsById: [WindowID: Window] = [:]
    let minimizedContainer = MacosMinimizedWindowsContainer()
    let popupContainer = MacosPopupWindowsContainer()
    var hiddenApps: Set<pid_t> = []

    var focusState: FrozenFocus
    /// The focus the callbacks last saw; nil until the first check after startup (AeroSpace initializes it lazily
    /// then, so no callback fires for the startup focus).
    var lastKnownFocus: FrozenFocus?
    var prevFocus: FrozenFocus?
    var prevFocusedWorkspaceName: String? {
        didSet { prevFocusedWorkspaceDate = now() }
    }
    var prevFocusedWorkspaceDate: Date = .distantPast
    var lastKnownNativeFocusedWindowId: WindowID?
    var isRunningFocusCallbacks = false

    /// Nil while disabled.
    var activeMode: String? = mainModeId
    var isEnabled = true
    /// True until `finishStartup()`: binds windows by monitor, matches `during-aerospace-startup`, and
    /// suppresses focus callbacks.
    var isStartup = true
    /// `layout --for-next-detected-window`.
    var layoutForNextDetectedWindow: LayoutCommand.LayoutDescription?
    /// The window currently dragged or resized with the mouse.
    var manipulatedWindowId: WindowID?
    var debugWindowsRecorder = DebugWindowsRecorder()
    /// Windows discovered while disabled; registered when enabled again (AeroSpace doesn't refresh while disabled).
    var detectionsWhileDisabled: [DetectedWindow] = []
    /// Restored placements (`restore(_:)`) waiting for their windows to be detected.
    var pendingRestore: PendingRestore?
    /// A snapshot was restored: its layouts win over the startup layout.
    var didRestoreSnapshot = false

    init(config: Config, configURL: URL?, platform: PlatformActions, monitors: [Monitor], processEnvironment: [String: String], now: @escaping () -> Date) {
        self.platform = platform
        self.processEnvironment = processEnvironment
        self.now = now
        self.config = config
        self.compiledConfig = CompiledConfig(config)
        self.configURL = configURL
        self.monitors = monitors.isEmpty ? [World.fallbackMonitor] : monitors
        self.focusState = FrozenFocus(windowId: nil, workspaceName: "", monitorId: 0)
        rememberMonitorFrames()

        // AeroSpace startup: persistent workspaces exist, every monitor shows a workspace, the first one is focused.
        for name in config.persistentWorkspaces { _ = workspace(named: name) }
        rearrangeWorkspacesOnMonitors(previousMonitors: [])
        let main = mainMonitor
        focusState = FrozenFocus(windowId: nil, workspaceName: activeWorkspace(on: main).name, monitorId: monitorId1Based(main) ?? 0)
        garbageCollectUnusedWorkspaces()
        if let first = allWorkspaces.first { _ = focusWorkspace(first) }
    }

    /// Used only if the engine reports no monitors at all.
    static let fallbackMonitor = Monitor(
        id: "fallback",
        name: "Unknown Monitor",
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        isMain: true
    )

    func applyConfig(_ newConfig: Config) {
        config = newConfig
        compiledConfig = CompiledConfig(newConfig)
    }

    func replaceMonitors(_ newMonitors: [Monitor]) {
        let previous = monitors
        monitors = newMonitors.isEmpty ? [World.fallbackMonitor] : newMonitors
        rememberMonitorFrames()
        rearrangeWorkspacesOnMonitors(previousMonitors: previous)
    }

    private func rememberMonitorFrames() {
        for monitor in monitors { lastKnownMonitorFrames[monitor.id] = monitor.frame }
    }

    /// The environment for `exec-*` commands: `[exec]` config applied to the process environment.
    var execEnvironment: [String: String] {
        config.exec.environment(processEnvironment: processEnvironment)
    }

    func window(byId id: WindowID) -> Window? { windowsById[id] }

    var allWindows: [Window] { windowsById.values.sorted { $0.id < $1.id } }
}

let mainModeId = "main"
