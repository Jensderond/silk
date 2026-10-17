import AppKit
import SilkAnimation
import SilkConfig
import SilkCore
import SilkIPC
import SilkPlatform

/// Glue between the modules: platform events drive the core, core plans drive the animator,
/// hotkeys and IPC requests run core commands. Main thread only.
///
/// Latency rule: commands (hotkeys, IPC) flush the layout synchronously right after they run;
/// platform events mark the model dirty and flush once at the end of the current main-queue turn,
/// so a burst of AX notifications costs one layout, with no added delay.
@MainActor
final class Engine {
    let platform: PlatformService
    private(set) var manager: WindowManager!
    let animator: Animator
    private let animationBridge: AnimationBridge
    private(set) var border: BorderController?
    let hotkeys = HotkeyCenter()
    private(set) var statusBar: StatusBarController!
    let stateStore = StateStore()
    let configWindow = MessageWindow()
    var ipcServer: IPCServer?

    var configURL: URL?
    var configLoad: ConfigLoadResult

    /// What the engine knows about each managed window, beyond the core's model.
    var windows: [UInt32: TrackedWindow] = [:]
    /// Windows created while the mouse was down (e.g. a browser tab being dragged out):
    /// detected on mouse-up so the drag isn't disturbed.
    var detectionsDeferredUntilMouseUp: [UInt32: WindowSnapshot] = [:]
    var hotkeyDescriptors: [UInt32: String] = [:]
    var isScreenLocked = false
    var isStarted = false
    private var isShutDown = false
    private var flushScheduled = false
    /// One frame: incoming windows get drawn before outgoing ones are hidden.
    static let parkDelay: TimeInterval = 0.016
    private var worldSaveTimer: Timer?
    private var lastSavedWorld: FrozenWorld?
    var lastFocusedWindow: UInt32?
    var focusFollowsMouseMonitor: Any?
    var hasConfigProblems = false
    var statusBarUpdateScheduled = false
    /// Opens the Accessibility walkthrough (set by the app delegate).
    var onRequestAccessibility: (() -> Void)?
    struct PendingFocus {
        let id = UUID()
        var window: UInt32
        var deadline: Date
        /// The most recent focus report held back while waiting.
        var deferred: (window: UInt32?, pid: pid_t)?
    }
    /// The window Silk last asked macOS to focus, until macOS confirms it.
    var pendingFocus: PendingFocus?
    static let focusConfirmationTimeout: TimeInterval = 0.4
    /// When each app was launched (only apps launched while Silk runs).
    var launchTimes: [pid_t: Date] = [:]

    init(configLoad: ConfigLoadResult) {
        self.configLoad = configLoad
        configURL = configLoad.url
        let config = configLoad.config
        platform = PlatformService(focusBackend: config.focusBackend.platformBackend)
        animationBridge = AnimationBridge(writer: platform.writer)
        animator = Animator(sink: animationBridge, settings: AnimationSettings(config.animations))
        statusBar = StatusBarController(actions: self)
    }

    // MARK: - Startup

    /// Starts observing the system, restores state from a previous run, enumerates existing
    /// windows and starts accepting hotkeys and CLI requests.
    func start() {
        let config = configLoad.config
        platform.start { [weak self] event in self?.handle(event) }
        manager = WindowManager(
            config: config,
            configURL: configURL,
            platform: self,
            monitors: platform.monitors.map(Monitor.init)
        )
        manager.delegate = self

        animator.onFrame = { [weak self] window, frame in self?.animationFrame(window: window, frame: frame) }
        animator.onComplete = { [weak self] window, epoch in self?.animationCompleted(window: window, epoch: epoch) }
        applyAppearanceSettings(config)

        if let frozen = loadFrozenWorld() { manager.restore(frozen) }
        isScreenLocked = Self.isSessionLocked

        startIPC()
        platform.enumerateAll { [weak self] snapshots in
            guard let self else { return }
            // Workers exist only now, so stranded windows can be written; detection then sees
            // them where they belong instead of in the corner.
            let restored = self.restoreStrandedWindows()
            for var snapshot in snapshots {
                if let frame = restored[snapshot.id] { snapshot.frame = frame }
                self.detect(snapshot, isStartup: true)
            }
            self.manager.finishStartup()
            self.isStarted = true
            self.flush()
        }
        registerHotkeys()
        reportConfigProblems(configLoad, manager.configDiagnostics)
        updateStatusBar()
        LoginItem.set(enabled: config.startAtLogin)
        warnAboutStageManager()

        worldSaveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveWorldIfChanged() }
        }
    }

    // MARK: - Layout flush

    /// Requests a flush at the end of the current main-queue turn (coalesces event bursts).
    func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.flush()
        }
    }

    /// Computes the core's plan and hands every change to the animator.
    func flush() {
        guard isStarted, !isScreenLocked, manager.needsLayout else { return }
        Trace.log("flush begins")
        let plan = manager.computeLayout()
        let (request, parks, revealed) = makeAnimationRequest(for: plan)
        Trace.log("flush epoch \(plan.epoch): \(request.moves.map { "\($0.window) \($0.kind) \($0.from) → \($0.to)" }) snaps \(request.snaps.map(\.window)) parks \(parks.snaps.map(\.window))")
        if !request.moves.isEmpty || !request.snaps.isEmpty {
            animator.apply(request)
        }
        // Windows coming back from a hidden workspace are behind whatever was on screen; raise them
        // (the focused one last) so all of them are seen sliding in, not just the focused one.
        if !plan.workspaceSwitches.isEmpty {
            for id in revealed where id != plan.focusedWindow { platform.raise(window: id) }
            if let focused = plan.focusedWindow, revealed.contains(focused) { platform.raise(window: focused) }
        }
        if !parks.snaps.isEmpty {
            // Like AeroSpace, show the incoming windows before hiding the outgoing ones, so a
            // workspace switch never flashes the desktop. The frame writer drops these writes if a
            // newer plan targeted the window in the meantime (older epoch).
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.parkDelay) { [weak self] in
                guard let self else { return }
                var current = parks
                current.snaps = parks.snaps.filter { snap in
                    guard let window = self.windows[snap.window], window.isHidden else { return false }
                    return window.target?.origin.isClose(to: snap.frame.origin) == true
                }
                if !current.snaps.isEmpty { self.animator.apply(current) }
            }
        }
        updateFocusBorder(plan)
        recordHiddenWindows()
    }

    // MARK: - Persistence

    private struct WorldEnvelope: Codable {
        var session: String
        var world: FrozenWorld
    }

    private func loadFrozenWorld() -> FrozenWorld? {
        guard let data = stateStore.loadWorld(),
              let envelope = try? JSONDecoder().decode(WorldEnvelope.self, from: data),
              envelope.session == StateStore.sessionID
        else { return nil }
        return envelope.world
    }

    func saveWorldIfChanged() {
        guard isStarted else { return }
        let world = manager.frozenWorld()
        guard world != lastSavedWorld,
              let data = try? JSONEncoder().encode(WorldEnvelope(session: StateStore.sessionID, world: world))
        else { return }
        lastSavedWorld = world
        stateStore.saveWorld(data)
    }

    /// Puts windows a crashed or killed previous run left parked in a corner back on screen.
    /// Returns the frames of the windows it moved.
    private func restoreStrandedWindows() -> [UInt32: CGRect] {
        let stranded = stateStore.loadStrandedWindows()
        stateStore.recordHidden([:])
        guard !stranded.isEmpty else { return [:] }
        let frames = stranded.map { ($0.windowID, $0.restoreFrame) }
        let written = platform.writeSynchronously(frames, deadline: .now() + 1)
        Trace.log("restored \(written.count) of \(frames.count) stranded windows")
        return Dictionary(frames.filter { written.contains($0.0) }, uniquingKeysWith: { first, _ in first })
    }

    private static var isSessionLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // MARK: - Termination

    /// Puts every hidden window back on screen. Called on quit, signals and disable.
    func restoreHiddenWindowsSynchronously() {
        guard manager != nil else { return }
        animator.snapAll()
        let frames = restoreFramesForHiddenWindows().map { ($0.key, $0.value.restoreFrame) }
        if !frames.isEmpty {
            _ = platform.writeSynchronously(frames, deadline: .now() + 1.5)
        }
        stateStore.recordHidden([:])
        saveWorldIfChanged()
        stateStore.flush()
    }

    func setBorder(_ controller: BorderController?) {
        border = controller
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        restoreHiddenWindowsSynchronously()
        hotkeys.unregisterAll()
        ipcServer?.stop()
        platform.stop()
    }
}
