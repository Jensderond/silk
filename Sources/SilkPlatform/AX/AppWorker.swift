import AppKit
import ApplicationServices
import os

/// What a worker needs from the rest of SilkPlatform. All members are thread-safe.
struct AppWorkerEnvironment {
    let directory: WindowDirectory
    let writer: FrameWriter
    let screenLock: ScreenLockState
    /// Posts an event towards the engine (the service hops to main).
    let emit: (PlatformEvent) -> Void
}

let platformLog = Logger(subsystem: "silk.platform", category: "ax")

/// One thread per app with its own CFRunLoop. Every AXUIElement of the app is created, used and
/// released on this thread only; other threads talk to it through ``perform(_:)``.
///
/// Members marked "worker thread" below must only be touched from blocks run by ``perform(_:)``
/// or from AX observer callbacks (which this run loop delivers).
final class AppWorker: FrameWriteTarget {
    let pid: pid_t
    let app: NSRunningApplication
    let identity: AppIdentity
    let environment: AppWorkerEnvironment

    private struct RunLoopState {
        var runLoop: CFRunLoop?
        var queued: [() -> Void] = []
        var isStopped = false
    }
    private let runLoopState = OSAllocatedUnfairLock(uncheckedState: RunLoopState())

    // MARK: Worker thread state

    var appElement: AXUIElement!
    var observer: AXObserver?
    var registeredAppNotifications: [String] = []
    var isRegistered = false
    var backoff = RegistrationBackoff()
    var registrationRetryTimer: CFRunLoopTimer?
    var initialEnumeration: (([WindowSnapshot]) -> Void)?

    var windows: [UInt32: TrackedWindow] = [:]
    var trackingCounter = 0
    var hasFailedReads = false
    var focusedWindowID: UInt32?
    var manipulatedWindowID: UInt32?
    var reconcileTimer: CFRunLoopTimer?
    var pendingFocusVerification: (window: UInt32, timer: CFRunLoopTimer)?

    var enhancedUserInterfaceWasOn: Bool?
    var isEnhancedUserInterfaceCleared = false
    var enhancedUserInterfaceRestoreTimer: CFRunLoopTimer?

    /// App-level notifications; registration counts as successful once the required ones are in.
    static let requiredAppNotifications = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification]
    static let optionalAppNotifications = [kAXMainWindowChangedNotification]

    /// Starts the worker thread. `initialEnumeration`, when given, receives the snapshots of the
    /// app's existing windows (instead of `windowAppeared` events) once registration first succeeds,
    /// or `[]` if the first registration attempt fails.
    init(app: NSRunningApplication, environment: AppWorkerEnvironment, initialEnumeration: (([WindowSnapshot]) -> Void)?) {
        self.pid = app.processIdentifier
        self.app = app
        self.identity = AppIdentity(pid: app.processIdentifier, bundleId: app.bundleIdentifier, name: app.localizedName)
        self.environment = environment
        self.initialEnumeration = initialEnumeration
        let thread = Thread { [self] in runThread() }
        thread.name = "silk.ax.\(identity.bundleId ?? String(pid))"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Runs `block` on the worker thread. Blocks submitted after ``stop()`` are dropped; returns
    /// false for those (the block will never run).
    @discardableResult
    func perform(_ block: @escaping () -> Void) -> Bool {
        runLoopState.withLockUnchecked { state in
            guard !state.isStopped else { return false }
            Self.enqueue(block, &state)
            return true
        }
    }

    /// Tears the worker down: removes every notification, releases AX objects in reverse order
    /// of creation and stops the run loop. With `emitDestroyed`, tracked windows are reported as
    /// destroyed first. `completion` runs on the worker thread after teardown.
    ///
    /// Stopping and enqueueing the teardown happen under one lock, so the teardown is the last
    /// block that ever runs: nothing submitted concurrently can run against the released elements.
    func stop(emitDestroyed: Bool, completion: (() -> Void)? = nil) {
        runLoopState.withLockUnchecked { state in
            guard !state.isStopped else { return }
            state.isStopped = true
            Self.enqueue({ [self] in
                tearDown(emitDestroyed: emitDestroyed)
                completion?()
                CFRunLoopStop(CFRunLoopGetCurrent())
            }, &state)
        }
    }

    private static func enqueue(_ block: @escaping () -> Void, _ state: inout RunLoopState) {
        if let runLoop = state.runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
            CFRunLoopWakeUp(runLoop)
        } else {
            state.queued.append(block)
        }
    }

    // MARK: - Thread lifecycle

    private func runThread() {
        pthread_setspecific(currentWorkerKey, Unmanaged.passUnretained(self).toOpaque())
        let runLoop = CFRunLoopGetCurrent()!
        var context = CFRunLoopSourceContext()
        let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)
        CFRunLoopAddSource(runLoop, keepAlive, .defaultMode)

        setUp()

        runLoopState.withLockUnchecked { state in
            state.runLoop = runLoop
            for block in state.queued {
                CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
            }
            state.queued = []
        }
        CFRunLoopRun()
        CFRunLoopRemoveSource(runLoop, keepAlive, .defaultMode)
        pthread_setspecific(currentWorkerKey, nil)
    }

    private func setUp() {
        appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, axMessagingTimeout)
        var observer: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &observer) == .success, let observer else {
            platformLog.error("AXObserverCreate failed for pid \(self.pid)")
            finishInitialEnumeration([])
            return
        }
        self.observer = observer
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        attemptRegistration()
    }

    private func tearDown(emitDestroyed: Bool) {
        cancel(&registrationRetryTimer)
        cancel(&reconcileTimer)
        cancel(&enhancedUserInterfaceRestoreTimer)
        if let verification = pendingFocusVerification {
            CFRunLoopTimerInvalidate(verification.timer)
            pendingFocusVerification = nil
        }
        if isEnhancedUserInterfaceCleared && !app.isTerminated {
            restoreEnhancedUserInterface()
        }
        for window in windows.values.sorted(by: { $0.trackingOrder > $1.trackingOrder }) {
            unsubscribe(window)
            environment.directory.unregister(window.id)
            environment.writer.forget(window: window.id, target: self)
            if emitDestroyed { environment.emit(.windowDestroyed(window.id)) }
        }
        windows = [:]
        if let observer {
            for name in registeredAppNotifications.reversed() {
                AXObserverRemoveNotification(observer, appElement, name as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        registeredAppNotifications = []
        observer = nil
        appElement = nil
        environment.writer.forget(target: self)
        finishInitialEnumeration([])
    }

    // MARK: - Registration

    /// Subscribes to the app-level notifications. Like AeroSpace, the app counts as registered as
    /// soon as one required notification is accepted: launching apps accept them one by one, and
    /// waiting for all of them would delay the first window. Missing ones are retried until added.
    func attemptRegistration() {
        guard let observer else { return }
        cancel(&registrationRetryTimer)
        var lastError = AXError.success
        var addedRequired = false
        for name in Self.requiredAppNotifications + Self.optionalAppNotifications where !registeredAppNotifications.contains(name) {
            let error = AXObserverAddNotification(observer, appElement, name as CFString, nil)
            if error == .success || error == .notificationAlreadyRegistered {
                registeredAppNotifications.append(name)
                if Self.requiredAppNotifications.contains(name) { addedRequired = true }
            } else if Self.requiredAppNotifications.contains(name) {
                lastError = error
            }
        }
        let missingRequired = Self.requiredAppNotifications.contains { !registeredAppNotifications.contains($0) }
        if missingRequired {
            if let delay = backoff.nextDelay() {
                registrationRetryTimer = schedule(after: delay) { [self] in attemptRegistration() }
            } else {
                platformLog.notice("Giving up AX registration for \(self.identity.bundleId ?? "pid \(self.pid)", privacy: .public): \(lastError.rawValue)")
            }
        } else {
            backoff.reset()
        }
        let acceptsAny = Self.requiredAppNotifications.contains { registeredAppNotifications.contains($0) }
        guard !isRegistered else {
            // Windows created while `kAXWindowCreated` was missing (or focused while
            // `kAXFocusedWindowChanged` was) went unseen; pick them up now.
            if addedRequired { reconcile() }
            return
        }
        guard acceptsAny else {
            finishInitialEnumeration([])
            return
        }
        isRegistered = true
        focusedWindowID = appElement.element(kAXFocusedWindowAttribute)?.windowID
        let snapshots = reconcile(discoveredByReconcile: true, collect: initialEnumeration != nil)
        finishInitialEnumeration(snapshots)
    }

    /// Retries registration now if it previously gave up or is waiting for its next backoff step.
    func retryRegistrationIfNeeded() {
        guard !isRegistered || Self.requiredAppNotifications.contains(where: { !registeredAppNotifications.contains($0) }) else { return }
        backoff.reset()
        attemptRegistration()
    }

    private func finishInitialEnumeration(_ snapshots: [WindowSnapshot]) {
        guard let completion = initialEnumeration else { return }
        initialEnumeration = nil
        completion(snapshots)
    }

    // MARK: - Run loop helpers (worker thread)

    func schedule(after delay: TimeInterval, _ body: @escaping () -> Void) -> CFRunLoopTimer {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0) { _ in body() }!
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
        return timer
    }

    func cancel(_ timer: inout CFRunLoopTimer?) {
        if let existing = timer { CFRunLoopTimerInvalidate(existing) }
        timer = nil
    }
}

/// Thread-specific pointer to the worker owning the current thread (for the C observer callback).
let currentWorkerKey: pthread_key_t = {
    var key = pthread_key_t()
    pthread_key_create(&key, nil)
    return key
}()

/// Single observer callback for all apps. App-level notifications carry a nil refcon; window
/// notifications carry the window id (destroyed elements no longer resolve to an id).
private let axObserverCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let raw = pthread_getspecific(currentWorkerKey) else { return }
    let worker = Unmanaged<AppWorker>.fromOpaque(raw).takeUnretainedValue()
    let windowID = refcon.map { UInt32(truncatingIfNeeded: UInt(bitPattern: $0)) }
    worker.handleNotification(notification as String, element: element, windowID: windowID)
}
