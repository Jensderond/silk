import AppKit
import QuartzCore

/// Drives window animations from a dedicated `.userInteractive` thread with one display
/// link per screen (`NSScreen.displayLink`, added to the animator thread's run loop; verified
/// on macOS 26.6 that links created on and added to a secondary thread's run loop fire there
/// at the display's rate). Links are paused while their screen has no tweens, so an idle
/// animator costs no CPU. Display links do not fire while the display sleeps; a watchdog
/// timer then completes overdue tweens so every move still ends with its final write.
///
/// Threading: `apply`, `cancel`, `snapAll`, `update(settings:)` and `presentedFrame` may be
/// called from any thread. `init` and `screensDidChange()` must run on main; `onFrame` and
/// `onComplete` are set and invoked on main. The `FrameSink` is called on the animator thread.
public final class Animator {
    /// Every frame written to a window (intermediate and final), coalesced per main-queue
    /// turn (only the latest frame per window is delivered). Main thread. Use for borders.
    public var onFrame: ((UInt32, CGRect) -> Void)?
    /// A window's animation (or snap) for `epoch` reached its final write. Retargeted or
    /// cancelled tweens never complete. Main thread.
    public var onComplete: ((_ window: UInt32, _ epoch: UInt64) -> Void)?

    private let loop: AnimatorLoop
    private let outbox = Outbox()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    @MainActor
    public init(sink: FrameSink, settings: AnimationSettings) {
        loop = AnimatorLoop(sink: sink, settings: settings, outbox: outbox)
        loop.drainOnMain = { [weak self] in self?.drainOutbox() }
        let thread = Thread { [loop] in loop.run() }
        thread.name = "silk.animator"
        thread.qualityOfService = .userInteractive
        thread.start()
        loop.waitUntilRunning()

        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
            $0.reduceMotionDidChange()
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) {
            $0.screensDidChange()
        }
        reduceMotionDidChange()
        screensDidChange()
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
        loop.perform { [loop] in loop.shutdown() }
    }

    /// Replaces the settings. Running tweens keep their curve; if animations are now off
    /// (or reduce motion now applies) every tween snaps.
    public func update(settings: AnimationSettings) {
        loop.perform { [loop] in loop.update(settings: settings) }
    }

    /// Starts, retargets or snaps windows. Returns immediately; the work happens on the
    /// animator thread, in call order.
    public func apply(_ request: AnimationRequest) {
        loop.perform { [loop] in loop.apply(request) }
    }

    /// Stops animating `window` without a final write (destroyed, or taken over by the user).
    public func cancel(window: UInt32) {
        loop.perform { [loop] in loop.cancel(window: window) }
    }

    /// Completes every running tween now with its final write (sleep, quit, disable).
    public func snapAll() {
        loop.perform { [loop] in loop.snapAll() }
    }

    /// The frame last written to `window` while it animates; nil when it is not animating.
    /// Lags `apply` until the animator thread has processed the request.
    public func presentedFrame(window: UInt32) -> CGRect? {
        outbox.presentedFrame(window: window)
    }

    /// Re-reads the screen list and rebuilds display links (also triggered automatically by
    /// `NSApplication.didChangeScreenParametersNotification`). Tweens on vanished screens
    /// continue on the primary screen.
    @MainActor
    public func screensDidChange() {
        let screens = NSScreen.screens.compactMap { screen -> ScreenInfo? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return ScreenInfo(displayID: number.uint32Value, screen: screen, maximumFramesPerSecond: screen.maximumFramesPerSecond)
        }
        loop.perform { [loop] in loop.setScreens(screens) }
    }

    @MainActor
    private func reduceMotionDidChange() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        loop.perform { [loop] in loop.setReduceMotion(reduceMotion) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (Animator) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { handler(self) }
        }
        observers.append((center, token))
    }

    private func drainOutbox() {
        let (frames, completions) = outbox.takePending()
        if let onFrame {
            for window in frames.keys.sorted() { onFrame(window, frames[window]!) }
        }
        if let onComplete {
            for completion in completions { onComplete(completion.window, completion.epoch) }
        }
    }
}

private struct ScreenInfo {
    let displayID: CGDirectDisplayID
    let screen: NSScreen
    let maximumFramesPerSecond: Int
}

/// State shared between the animator thread (writer) and other threads (readers).
private final class Outbox: @unchecked Sendable {  // all state behind `lock`
    private let lock = NSLock()
    private var presented: [UInt32: CGRect] = [:]
    private var pendingFrames: [UInt32: CGRect] = [:]
    private var pendingCompletions: [AnimationCompletion] = []
    private var drainScheduled = false

    func presentedFrame(window: UInt32) -> CGRect? {
        lock.withLock { presented[window] }
    }

    /// Records a step's results; returns true when the caller must schedule a main drain.
    func publish(_ output: SchedulerOutput, presented: [UInt32: CGRect]) -> Bool {
        lock.withLock {
            self.presented = presented
            for write in output.writes { pendingFrames[write.window] = write.frame }
            pendingCompletions += output.completions
            guard !drainScheduled, !pendingFrames.isEmpty || !pendingCompletions.isEmpty else { return false }
            drainScheduled = true
            return true
        }
    }

    func takePending() -> ([UInt32: CGRect], [AnimationCompletion]) {
        lock.withLock {
            defer {
                pendingFrames = [:]
                pendingCompletions = []
                drainScheduled = false
            }
            return (pendingFrames, pendingCompletions)
        }
    }
}

/// Everything that lives on the animator thread. Other threads only call `perform`
/// (and `waitUntilRunning` during setup), hence the unchecked conformance.
private final class AnimatorLoop: @unchecked Sendable {
    /// Grace period after a tween's deadline before the watchdog completes it.
    private static let watchdogGrace = 0.1
    /// Frame interval assumed for a display until its link has fired.
    private static let defaultFrameInterval = 1.0 / 60

    private let sink: FrameSink
    private let outbox: Outbox
    private var scheduler: AnimationScheduler
    /// Set before the thread starts, read on the animator thread.
    var drainOnMain: (() -> Void)?

    private var runLoop: CFRunLoop!
    private let running = DispatchSemaphore(value: 0)
    private var isShutDown = false
    private var links: [CGDirectDisplayID: CADisplayLink] = [:]
    /// Per display: the measured frame interval of its last tick, or 1 / max refresh rate.
    private var frameIntervals: [CGDirectDisplayID: Double] = [:]
    private var primaryDisplay: CGDirectDisplayID?
    private var watchdog: CFRunLoopTimer?

    init(sink: FrameSink, settings: AnimationSettings, outbox: Outbox) {
        self.sink = sink
        self.outbox = outbox
        scheduler = AnimationScheduler(settings: settings)
    }

    // MARK: Thread

    func run() {
        runLoop = CFRunLoopGetCurrent()
        // A port source keeps the run loop alive while there are no links or timers.
        let keepAlive = NSMachPort()
        RunLoop.current.add(keepAlive, forMode: .common)
        let timer = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 1e9, 0, 0) { [unowned self] _ in
            watchdogFired()
        }
        CFRunLoopAddTimer(runLoop, timer, .commonModes)
        watchdog = timer
        running.signal()
        while !isShutDown {
            _ = CFRunLoopRunInMode(.defaultMode, 1e9, false)
        }
        CFRunLoopTimerInvalidate(timer)
        RunLoop.current.remove(keepAlive, forMode: .common)
    }

    func waitUntilRunning() { running.wait() }

    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    func shutdown() {
        deliver(scheduler.snapAll())
        for link in links.values { link.invalidate() }
        links = [:]
        isShutDown = true
        CFRunLoopStop(runLoop)
    }

    // MARK: Commands

    func apply(_ request: AnimationRequest) {
        guard let primaryDisplay else {
            deliver(scheduler.apply(request, now: CACurrentMediaTime(), cost: cost))
            deliver(scheduler.snapAll())
            return
        }
        var request = request
        for index in request.moves.indices where links[request.moves[index].displayID] == nil {
            request.moves[index].displayID = primaryDisplay
        }
        // Write the new tweens' frame for the coming vsync (one frame interval into the curve) right
        // away instead of at the next tick, up to a frame later. Their first tick then continues
        // exactly one frame further, in phase with vsync (`AnimationScheduler.leadIn`).
        let now = CACurrentMediaTime()
        deliver(scheduler.apply(request, now: now, cost: cost))
        for displayID in Set(request.moves.map(\.displayID)) where scheduler.hasTweens(on: displayID) {
            let interval = frameInterval(displayID)
            deliver(scheduler.leadIn(display: displayID, now: now + interval, frameInterval: interval, cost: cost))
        }
        scheduleLinksAndWatchdog()
    }

    func update(settings: AnimationSettings) {
        scheduler.settings = settings
        if scheduler.isSnapping { snapAll() }
    }

    func setReduceMotion(_ reduceMotion: Bool) {
        scheduler.reduceMotion = reduceMotion
        if scheduler.isSnapping { snapAll() }
    }

    func cancel(window: UInt32) {
        deliver(scheduler.cancel(window: window))
        scheduleLinksAndWatchdog()
    }

    func snapAll() {
        deliver(scheduler.snapAll())
        scheduleLinksAndWatchdog()
    }

    func setScreens(_ screens: [ScreenInfo]) {
        let available = Set(screens.map(\.displayID))
        for (displayID, link) in links where !available.contains(displayID) {
            link.invalidate()
            links[displayID] = nil
            frameIntervals[displayID] = nil
        }
        for info in screens where links[info.displayID] == nil {
            let target = DisplayLinkTarget(loop: self, displayID: info.displayID)
            let link = info.screen.displayLink(target: target, selector: #selector(DisplayLinkTarget.step(_:)))
            let fps = Float(info.maximumFramesPerSecond)
            if fps > 0 {
                // Ask for the panel's full rate (120 Hz on ProMotion) rather than leaving it to the system.
                link.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
                frameIntervals[info.displayID] = 1 / Double(fps)
            }
            link.isPaused = true
            link.add(to: .current, forMode: .common)
            links[info.displayID] = link
        }
        primaryDisplay = screens.first?.displayID
        if let primaryDisplay {
            scheduler.reassignDisplays(available: available, fallback: primaryDisplay)
        } else {
            deliver(scheduler.snapAll())
        }
        scheduleLinksAndWatchdog()
    }

    // MARK: Ticks

    fileprivate func displayLinkFired(_ displayID: CGDirectDisplayID, _ link: CADisplayLink) {
        let measured = link.targetTimestamp - link.timestamp
        let frameInterval = measured > 0 ? measured : (link.duration > 0 ? link.duration : frameInterval(displayID))
        frameIntervals[displayID] = frameInterval
        deliver(scheduler.tick(display: displayID, now: link.targetTimestamp, frameInterval: frameInterval, cost: cost))
        scheduleLinksAndWatchdog()
    }

    private func watchdogFired() {
        deliver(scheduler.finishOverdue(now: CACurrentMediaTime(), grace: Self.watchdogGrace))
        scheduleLinksAndWatchdog()
    }

    private func cost(_ window: UInt32) -> WriteCost { sink.cost(window: window) }

    private func frameInterval(_ displayID: CGDirectDisplayID) -> Double {
        frameIntervals[displayID] ?? Self.defaultFrameInterval
    }

    /// Runs exactly the links whose display has tweens and arms the watchdog for the
    /// earliest deadline.
    private func scheduleLinksAndWatchdog() {
        let active = scheduler.activeDisplays
        for (displayID, link) in links {
            let paused = !active.contains(displayID)
            if link.isPaused != paused { link.isPaused = paused }
        }
        guard let watchdog else { return }
        if let deadline = scheduler.nextDeadline {
            let delay = max(deadline + Self.watchdogGrace - CACurrentMediaTime(), 0)
            CFRunLoopTimerSetNextFireDate(watchdog, CFAbsoluteTimeGetCurrent() + delay)
        } else {
            CFRunLoopTimerSetNextFireDate(watchdog, .greatestFiniteMagnitude)
        }
    }

    private func deliver(_ output: SchedulerOutput) {
        for pid in output.appsBegan { sink.animationsBegan(pid: pid) }
        if !output.writes.isEmpty { sink.submit(output.writes) }
        for pid in output.appsEnded { sink.animationsEnded(pid: pid) }
        var presented: [UInt32: CGRect] = [:]
        for window in scheduler.animatingWindows {
            presented[window] = scheduler.presentedFrame(window: window)
        }
        if outbox.publish(output, presented: presented), let drainOnMain {
            DispatchQueue.main.async(execute: drainOnMain)
        }
    }
}

/// Display-link target; the link retains it, it holds the loop weakly.
private final class DisplayLinkTarget: NSObject {
    private weak var loop: AnimatorLoop?
    private let displayID: CGDirectDisplayID

    init(loop: AnimatorLoop, displayID: CGDirectDisplayID) {
        self.loop = loop
        self.displayID = displayID
    }

    @objc func step(_ link: CADisplayLink) {
        loop?.displayLinkFired(displayID, link)
    }
}
