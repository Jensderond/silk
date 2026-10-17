import CoreGraphics
import Foundation
import SilkConfig

/// The window manager core: AeroSpace's model, commands and callbacks, driven by platform events and producing
/// layout plans. Synchronous and main-thread only; all side effects go through `PlatformActions`.
public final class WindowManager {
    public weak var delegate: WindowManagerDelegate?
    let world: World
    private var planner = LayoutPlanner()
    private var lastMenuBarModel: MenuBarModel?
    /// A native focus report for a window that wasn't detected yet.
    private var pendingNativeFocusWindowId: WindowID?

    /// True when the model changed since the last `computeLayout()`.
    public private(set) var needsLayout = true

    /// - Parameters:
    ///   - monitors: in `NSScreen.screens` order.
    ///   - processEnvironment: the base environment for `exec-*` commands, before `[exec]` config.
    ///   - now: the clock (injectable for tests).
    public init(
        config: Config,
        configURL: URL? = nil,
        platform: PlatformActions,
        monitors: [Monitor],
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping () -> Date = Date.init
    ) {
        world = World(config: config, configURL: configURL, platform: platform, monitors: monitors, processEnvironment: processEnvironment, now: now)
        world.observer = self
    }

    // MARK: State

    public var config: Config { world.config }
    /// Command parse errors in the current config's scripts, formatted like config errors.
    public var configDiagnostics: [ConfigDiagnostic] { world.compiledConfig.diagnostics }
    public var isEnabled: Bool { world.isEnabled }
    /// The active binding mode; nil while disabled.
    public var activeMode: String? { world.activeMode }
    /// The hotkeys to register: the bindings of the active mode.
    public var activeBindings: [Binding] {
        guard let mode = world.activeMode, let bindings = world.config.modes[mode]?.bindings else { return [] }
        return bindings.values.sorted { $0.descriptor < $1.descriptor }
    }
    public var focusedWorkspace: String { world.focus.workspace.name }
    public var focusedWindow: WindowID? { world.focus.window?.id }
    /// True until `finishStartup()`.
    public var isStartup: Bool { world.isStartup }

    // MARK: Lifecycle

    /// Ends startup after the initial window enumeration: applies AeroSpace's startup layout (accordion for more
    /// than three windows on the focused workspace) unless a snapshot was restored, and runs `after-startup-command`.
    public func finishStartup() {
        guard world.isStartup else { return }
        commandSession(mutates: true) {
            if !world.didRestoreSnapshot {
                let root = world.focus.workspace.rootTilingContainer
                root.layout = root.children.count <= 3 ? .tiles : .accordion
            }
            world.runCallback(world.compiledConfig.afterStartupCommand, env: .empty)
        }
        world.isStartup = false
    }

    // MARK: Platform events

    /// A window appeared. At startup it joins the workspace of the monitor under its centre, later the focused one.
    public func windowDetected(_ window: DetectedWindow, isStartup: Bool) {
        if let existing = world.window(byId: window.id) {
            existing.title = window.title
            return
        }
        guard world.isEnabled else {
            world.detectionsWhileDisabled.removeAll { $0.id == window.id }
            world.detectionsWhileDisabled.append(window)
            return
        }
        eventSession {
            let registered = world.register(window, bindByMonitorUnderCenter: isStartup)
            if window.isFocused || pendingNativeFocusWindowId == window.id {
                pendingNativeFocusWindowId = nil
                world.syncFocusFromNative(registered)
            }
        }
    }

    /// The platform re-classified a window (e.g. a "popup" that turned out to be a real window).
    public func windowReclassified(_ id: WindowID, kind: WindowKind) {
        guard let window = world.window(byId: id) else { return }
        eventSession { world.reclassify(window, as: kind) }
    }

    /// The window is gone.
    public func windowDestroyed(_ id: WindowID) {
        world.detectionsWhileDisabled.removeAll { $0.id == id }
        guard let window = world.window(byId: id) else { return }
        eventSession { world.garbageCollect(window) }
    }

    /// The window is alive but no longer on screen (another Space, app-hidden by itself): it leaves the layout
    /// but keeps its slot.
    public func windowOrderedOut(_ id: WindowID) {
        guard let window = world.window(byId: id) else { return }
        eventSession { world.orderOut(window) }
    }

    /// An ordered-out window is back on screen.
    public func windowOrderedIn(_ id: WindowID) {
        guard let window = world.window(byId: id) else { return }
        eventSession { world.orderIn(window) }
    }

    /// macOS minimized or restored the window.
    public func windowMinimizedChanged(_ id: WindowID, isMinimized: Bool) {
        guard let window = world.window(byId: id) else { return }
        eventSession { window.isMacosMinimized = isMinimized }
    }

    /// The window entered or left macOS native fullscreen.
    public func windowFullscreenChanged(_ id: WindowID, isFullscreen: Bool) {
        guard let window = world.window(byId: id) else { return }
        eventSession { window.isMacosFullscreen = isFullscreen }
    }

    /// Updates the title cache (`%{window-title}`, title matchers of later rules).
    public func windowTitleChanged(_ id: WindowID, title: String) {
        world.window(byId: id)?.title = title
    }

    /// macOS focused `window` (nil: an app without a focused window). The core's focus follows.
    public func nativeFocusChanged(window id: WindowID?, pid: pid_t) {
        guard world.isEnabled else { return }
        guard let id else {
            eventSession { world.syncFocusFromNative(nil) }
            return
        }
        guard let window = world.window(byId: id) else {
            pendingNativeFocusWindowId = id
            return
        }
        eventSession { world.syncFocusFromNative(window) }
    }

    /// The user is dragging or resizing a window with the mouse. Dragging a tile over another swaps them (or moves
    /// it to another monitor); resizing adjusts tile weights. `.ended` finishes the gesture.
    public func userManipulation(window id: WindowID, frame: CGRect, phase: ManipulationPhase) {
        guard let window = world.window(byId: id) else { return }
        guard world.isEnabled else {
            window.lastKnownFrame = frame
            return
        }
        commandSession(mutates: true) {
            switch phase {
                case .began, .changed:
                    world.handleUserManipulation(window, frame: frame)
                    refreshLayoutBookkeeping()
                case .ended:
                    if world.manipulatedWindowId == window.id {
                        window.lastKnownFrame = frame
                    } else {
                        world.handleUserManipulation(window, frame: frame) // A gesture with a single event
                    }
                    world.endUserManipulation()
            }
        }
    }

    /// The app moved/resized its window itself. Floating windows adopt the frame; tiles get their planned frame
    /// re-asserted by the engine.
    public func appChangedFrame(window id: WindowID, frame: CGRect) {
        guard let window = world.window(byId: id) else { return }
        window.lastKnownFrame = frame
        needsLayout = true
    }

    /// The left mouse button went up anywhere: ends a mouse gesture, and a click on another monitor's desktop
    /// focuses that monitor's workspace.
    public func leftMouseUp(at point: CGPoint) {
        guard world.isEnabled else { return }
        commandSession(mutates: true) {
            world.endUserManipulation()
            let clickedMonitor = world.monitorApproximation(point)
            let workspace = world.activeWorkspace(on: clickedMonitor)
            if clickedMonitor.visibleFrame.containsPoint(point) && workspace !== world.focus.workspace {
                world.focusWorkspace(workspace)
            }
        }
    }

    /// Focus-follows-mouse: the mouse moved to `point` over an AX window. Returns the window that got focus.
    @discardableResult
    public func focusFollowsMouse(at point: CGPoint) -> WindowID? {
        guard world.isEnabled, world.config.focusFollowsMouse, let window = world.focusFollowsMouse(at: point) else { return nil }
        commandSession(mutates: true, syncNativeFocus: false) {
            world.focusWindow(window)
            world.platform.focus(window: window.id, pid: window.pid)
        }
        return window.id
    }

    /// The app was hidden (cmd-h). With `automatically-unhide-macos-hidden-apps` it's unhidden right away.
    public func appHidden(pid: pid_t) {
        guard world.isEnabled else { return }
        world.hiddenApps.insert(pid)
        guard world.config.automaticallyUnhideMacosHiddenApps else {
            eventSession {}
            return
        }
        commandSession(mutates: true, syncNativeFocus: false) {
            // "Hide app" (cmd-h) gives focus back; "Hide others" (cmd-alt-h) doesn't
            if let window = world.prevFocusLive?.window, world.hiddenApps.contains(window.pid), world.hiddenApps.count == 1 {
                world.focusWindow(window)
                world.platform.focus(window: window.id, pid: window.pid)
            }
            for hiddenPid in world.hiddenApps.sorted() {
                world.platform.unhideApp(pid: hiddenPid)
            }
        }
    }

    public func appUnhidden(pid: pid_t) {
        world.hiddenApps.remove(pid)
        eventSession {}
    }

    /// The app quit: all its windows are gone.
    public func appTerminated(pid: pid_t) {
        world.hiddenApps.remove(pid)
        world.detectionsWhileDisabled.removeAll { $0.pid == pid }
        eventSession {
            for window in world.allWindows where window.pid == pid {
                world.garbageCollect(window)
            }
        }
    }

    /// The display configuration changed (`monitors` in `NSScreen.screens` order). As in AeroSpace, workspaces are
    /// tied to screen positions (monitor top-left corners): visible workspaces move to the monitor closest to where
    /// theirs was, and invisible ones belong to the monitor nearest to where they were last shown.
    public func monitorsChanged(_ monitors: [Monitor]) {
        eventSession { world.replaceMonitors(monitors) }
    }

    /// The engine finished writing a window and read back `presentedFrame`.
    public func applied(window id: WindowID, presentedFrame: CGRect) {
        world.window(byId: id)?.lastKnownFrame = presentedFrame
    }

    // MARK: Layout

    /// The plan for the current model. Cheap; call once per main-queue turn when `needsLayout`.
    public func computeLayout() -> LayoutPlan {
        needsLayout = false
        return planner.makePlan(world)
    }

    /// Frames to restore every window to before quitting: centered on its monitor at its last floating size.
    public func terminationFrames() -> [WindowID: CGRect] {
        var result: [WindowID: CGRect] = [:]
        for window in world.windowsById.values {
            let monitor = window.lastKnownFrame.map { world.monitorApproximation($0.center) } ?? world.mainMonitor
            let visible = monitor.visibleFrame
            let size = window.lastFloatingSize ?? visible.size
            result[window.id] = CGRect(
                x: visible.minX + (visible.width - size.width) / 2,
                y: visible.minY + (visible.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
        }
        return result
    }

    /// AeroSpace's menu bar state.
    public func menuBarModel() -> MenuBarModel { MenuBarModel(world) }

    // MARK: Persistence

    public func frozenWorld() -> FrozenWorld { world.frozenWorld() }

    /// Restores a snapshot: monitor assignment and focus now, windows as they get detected. Call it right after
    /// `init`, before the startup `windowDetected` calls (windows already known are placed immediately too).
    public func restore(_ frozen: FrozenWorld) {
        eventSession { world.restore(frozen) }
    }

    // MARK: Sessions

    /// Model upkeep after a platform event (AeroSpace refresh session).
    func eventSession(_ body: () -> Void) {
        body()
        world.refreshModel()
        world.normalizeLayoutReason()
        needsLayout = true
        notifyMenuBarIfChanged()
    }

    /// Upkeep around commands (AeroSpace light session): if the focused window changed, macOS focus follows.
    @discardableResult
    func commandSession<T>(mutates: Bool, syncNativeFocus: Bool = true, _ body: () -> T) -> T {
        let focusBefore = world.focus.window
        world.refreshModel()
        let result = body()
        world.refreshModel()
        world.normalizeLayoutReason()
        let focusAfter = world.focus.window
        if syncNativeFocus, focusBefore !== focusAfter, let focusAfter {
            world.platform.focus(window: focusAfter.id, pid: focusAfter.pid)
        }
        if mutates { needsLayout = true }
        notifyMenuBarIfChanged()
        return result
    }

    /// Re-runs layout bookkeeping (last applied rects, weights) without emitting a plan, so consecutive mouse
    /// events hit-test against the current arrangement.
    private func refreshLayoutBookkeeping() {
        var layout = TreeLayout(world: world)
        for monitor in world.monitors {
            layout.layoutWorkspace(world.activeWorkspace(on: monitor))
        }
    }

    private func notifyMenuBarIfChanged() {
        let model = MenuBarModel(world)
        if model != lastMenuBarModel {
            lastMenuBarModel = model
            delegate?.windowManagerDidChangeMenuBarState(self)
        }
    }
}

extension WindowManager: WorldObserver {
    func worldDidActivateMode(_ mode: String?) { delegate?.windowManager(self, didActivateMode: mode) }
    func worldDidReloadConfig(_ config: Config) { delegate?.windowManager(self, didReloadConfig: config) }
    func worldDidChangeConfigMessage(_ message: String?) { delegate?.windowManager(self, didChangeConfigMessage: message) }
    func worldDidChangeEnabled(_ isEnabled: Bool) { delegate?.windowManager(self, didChangeEnabled: isEnabled) }
}
