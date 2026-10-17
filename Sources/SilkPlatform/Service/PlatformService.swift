import AppKit
import os

/// SilkPlatform's façade for the engine: owns the per-app AX workers, turns AX and system
/// notifications into ``PlatformEvent``s and performs window actions.
///
/// Main thread only, except ``writer`` (thread-safe; used by the animator thread).
/// Actions never block the main thread: they are queued on the target app's worker.
public final class PlatformService {
    static let monitorDebounce: TimeInterval = 0.75
    static let enumerationTimeout: TimeInterval = 2
    static let lockScreenBundleId = "com.apple.loginwindow"

    /// Thread-safe frame writer (latest-wins per window, epoch-checked).
    public let writer: FrameWriter
    /// Current displays, sorted like AeroSpace (left to right, then top to bottom).
    public private(set) var monitors: [MonitorInfo] = []
    public var focusBackend: FocusBackend

    private let directory: WindowDirectory
    private let screenLock = ScreenLockState()
    private var workers: [pid_t: AppWorker] = [:]
    private var activationPolicyObservations: [pid_t: NSKeyValueObservation] = [:]
    private var onEvent: ((PlatformEvent) -> Void)?
    private var bufferedEvents: [PlatformEvent] = []
    private var pendingEnumerations = 0
    private var observerTokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var mouseUpMonitor: Any?
    private var monitorDebounce: DispatchWorkItem?

    public init(focusBackend: FocusBackend = .appKit) {
        let directory = WindowDirectory()
        self.directory = directory
        self.focusBackend = focusBackend
        self.writer = FrameWriter(resolveTarget: { directory.worker(for: $0) })
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Starts observing the system. `onEvent` is called on the main thread. Call
    /// ``enumerateAll(completion:)`` next to pick up the apps and windows that already exist.
    public func start(onEvent: @escaping (PlatformEvent) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.onEvent = onEvent
        screenLock.isLocked = ScreenLockState.querySession()
        monitors = MonitorInfo.current()
        observeWorkspace()
        observeSystem()
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.leftMouseUp()
        }
    }

    /// Stops observing and tears down every worker. No further events are delivered.
    public func stop() {
        for (center, token) in observerTokens { center.removeObserver(token) }
        observerTokens = []
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        mouseUpMonitor = nil
        monitorDebounce?.cancel()
        activationPolicyObservations = [:]
        for worker in workers.values { worker.stop(emitDestroyed: false) }
        workers = [:]
        onEvent = nil
    }

    /// Startup enumeration: registers every regular app (plus already tracked accessory apps)
    /// in parallel and returns the snapshots of their windows. Never blocks the main thread.
    /// Apps that don't answer within 2 s report their windows later as
    /// `windowAppeared(_, discoveredByReconcile: true)`. Events produced meanwhile are held
    /// back and delivered right after `completion`.
    public func enumerateAll(completion: @escaping ([WindowSnapshot]) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        pendingEnumerations += 1
        var snapshots: [WindowSnapshot] = []
        var remaining = 0
        var isFinished = false
        let finish = { [weak self] in
            guard !isFinished else { return }
            isFinished = true
            completion(snapshots)
            self?.enumerationFinished()
        }
        let receive: ([WindowSnapshot]) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                if isFinished {
                    for snapshot in result { self?.deliver(.windowAppeared(snapshot, discoveredByReconcile: true)) }
                    return
                }
                snapshots += result
                remaining -= 1
                if remaining == 0 { finish() }
            }
        }

        var started = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && shouldTrack(app) {
            remaining += 1
            started.insert(app.processIdentifier)
            if let worker = workers[app.processIdentifier] {
                worker.perform { worker.enumerate(receive) }
            } else {
                workers[app.processIdentifier] = makeWorker(app, initialEnumeration: receive)
            }
        }
        for (pid, worker) in workers where !started.contains(pid) {
            remaining += 1
            worker.perform { worker.enumerate(receive) }
        }
        if remaining == 0 {
            finish()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.enumerationTimeout, execute: finish)
        }
    }

    // MARK: - Queries

    public var mouseLocation: CGPoint { InputState.mouseLocation }
    public var isLeftMouseDown: Bool { InputState.isLeftMouseDown }
    public var isSecureInputEnabled: Bool { InputState.isSecureInputEnabled }

    public func runningApps() -> [AppInfo] {
        NSWorkspace.shared.runningApplications.map(AppInfo.init)
    }

    // MARK: - Actions

    /// Focuses a window (see ``FocusBackend``). Confirmation arrives as `focusedWindowChanged`.
    public func focus(window: UInt32, pid: pid_t) {
        guard let worker = workers[pid] ?? directory.worker(for: window) else {
            if let app = NSRunningApplication(processIdentifier: pid) { AppWorker.activate(app) }
            return
        }
        let backend = focusBackend
        let allowShortcut = !NSScreen.screensHaveSeparateSpaces || NSScreen.screens.count == 1
        worker.perform { worker.focus(window, backend: backend, allowShortcut: allowShortcut) }
    }

    public func raise(window: UInt32) {
        onWorker(of: window) { $0.raise(window) }
    }

    /// Presses the window's close button. `completion` (main thread) tells whether a close button was pressed.
    public func close(window: UInt32, completion: ((Bool) -> Void)? = nil) {
        guard let worker = directory.worker(for: window) else {
            completion?(false)
            return
        }
        let accepted = worker.perform {
            let pressed = worker.close(window)
            if let completion { DispatchQueue.main.async { completion(pressed) } }
        }
        if !accepted { completion?(false) }
    }

    public func setMinimized(window: UInt32, _ minimized: Bool) {
        onWorker(of: window) { $0.setMinimized(window, minimized) }
    }

    public func setFullscreen(window: UInt32, _ fullscreen: Bool) {
        onWorker(of: window) { $0.setFullscreen(window, fullscreen) }
    }

    public func unhideApp(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.unhide()
    }

    public func moveMouse(to point: CGPoint) {
        InputState.moveMouse(to: point)
    }

    /// Termination restore; see ``FrameWriter/writeSynchronously(_:deadline:)``. Windows no worker
    /// tracks (yet) — at startup, before enumeration, that is all of them — are written directly.
    @discardableResult
    public func writeSynchronously(_ frames: [(UInt32, CGRect)], deadline: DispatchTime) -> Set<UInt32> {
        let untracked = frames.filter { directory.worker(for: $0.0) == nil }
        guard !untracked.isEmpty else { return writer.writeSynchronously(frames, deadline: deadline) }
        let written = OSAllocatedUnfairLock(initialState: Set<UInt32>())
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            let done = UntrackedFrameRestore.write(untracked)
            written.withLock { $0.formUnion(done) }
        }
        let tracked = writer.writeSynchronously(frames, deadline: deadline)
        _ = group.wait(timeout: deadline)
        return written.withLock { $0 }.union(tracked)
    }

    private func onWorker(of window: UInt32, _ body: @escaping (AppWorker) -> Void) {
        guard let worker = directory.worker(for: window) else { return }
        worker.perform { body(worker) }
    }

    // MARK: - Events

    private func deliver(_ event: PlatformEvent) {
        if pendingEnumerations > 0 {
            bufferedEvents.append(event)
        } else {
            onEvent?(event)
        }
    }

    private func enumerationFinished() {
        pendingEnumerations -= 1
        guard pendingEnumerations == 0 else { return }
        let events = bufferedEvents
        bufferedEvents = []
        for event in events { onEvent?(event) }
    }

    // MARK: - Workers

    private func shouldTrack(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier != getpid() && app.bundleIdentifier != Self.lockScreenBundleId && !app.isTerminated
    }

    private func makeWorker(_ app: NSRunningApplication, initialEnumeration: (([WindowSnapshot]) -> Void)? = nil) -> AppWorker {
        let environment = AppWorkerEnvironment(directory: directory, writer: writer, screenLock: screenLock) { [weak self] event in
            DispatchQueue.main.async { self?.deliver(event) }
        }
        return AppWorker(app: app, environment: environment, initialEnumeration: initialEnumeration)
    }

    @discardableResult
    private func ensureWorker(_ app: NSRunningApplication) -> AppWorker? {
        guard shouldTrack(app) else { return nil }
        if let existing = workers[app.processIdentifier] { return existing }
        let worker = makeWorker(app)
        workers[app.processIdentifier] = worker
        return worker
    }

    private func reconcileAll() {
        for worker in workers.values { worker.perform { worker.reconcile() } }
    }

    // MARK: - System observation

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ handler: @escaping (NSRunningApplication?) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { notification in
                handler(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            }
            observerTokens.append((center, token))
        }
        observe(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            guard let self, let app, shouldTrack(app) else { return }
            deliver(.appLaunched(app.processIdentifier))
            if app.activationPolicy == .regular {
                ensureWorker(app)
            } else {
                observeActivationPolicy(app)
            }
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            appTerminated(app.processIdentifier)
        }
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            guard let self, let app, app.bundleIdentifier != Self.lockScreenBundleId else { return }
            deliver(.appActivated(app.processIdentifier))
            if let worker = ensureWorker(app) { worker.perform { worker.handleActivation() } }
        }
        observe(NSWorkspace.didHideApplicationNotification) { [weak self] app in
            if let app { self?.deliver(.appHidden(app.processIdentifier)) }
        }
        observe(NSWorkspace.didUnhideApplicationNotification) { [weak self] app in
            if let app { self?.deliver(.appUnhidden(app.processIdentifier)) }
        }
        observe(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            guard let self else { return }
            deliver(.activeSpaceChanged)
            for worker in workers.values { worker.perform { worker.handleSpaceChange() } }
        }
        observe(NSWorkspace.willSleepNotification) { [weak self] _ in
            self?.deliver(.willSleep)
        }
        observe(NSWorkspace.didWakeNotification) { [weak self] _ in
            self?.deliver(.didWake)
            self?.reconcileAll()
        }
    }

    private func observeSystem() {
        let distributed = DistributedNotificationCenter.default()
        let locked = distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLock.isLocked = true
            self?.deliver(.screenLocked)
        }
        let unlocked = distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLock.isLocked = false
            self?.deliver(.screenUnlocked)
            self?.reconcileAll()
        }
        let screens = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.screenParametersChanged()
        }
        observerTokens += [(distributed, locked), (distributed, unlocked), (NotificationCenter.default, screens)]
    }

    /// Apps that launch as accessory/prohibited and later become regular (common for Electron and
    /// apps that show a window only after login) are picked up when their policy flips.
    private func observeActivationPolicy(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        activationPolicyObservations[pid] = app.observe(\.activationPolicy) { [weak self] app, _ in
            guard app.activationPolicy == .regular else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                activationPolicyObservations[pid] = nil
                ensureWorker(app)
            }
        }
    }

    private func appTerminated(_ pid: pid_t) {
        activationPolicyObservations[pid] = nil
        guard let worker = workers.removeValue(forKey: pid) else {
            deliver(.appTerminated(pid))
            return
        }
        worker.stop(emitDestroyed: true) { [weak self] in
            DispatchQueue.main.async { self?.deliver(.appTerminated(pid)) }
        }
    }

    private func leftMouseUp() {
        deliver(.leftMouseUp(InputState.mouseLocation))
        for worker in workers.values { worker.perform { worker.handleLeftMouseUp() } }
    }

    private func screenParametersChanged() {
        monitorDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let current = MonitorInfo.current()
            if current != monitors {
                monitors = current
                deliver(.monitorsChanged(current))
            }
            reconcileAll()
        }
        monitorDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.monitorDebounce, execute: work)
    }
}
