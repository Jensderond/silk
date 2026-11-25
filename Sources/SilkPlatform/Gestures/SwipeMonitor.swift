import Foundation
import SilkPrivateAPI

/// Watches every trackpad for three-finger horizontal swipes, system-wide. macOS only delivers such
/// gestures to the frontmost app, so this reads raw touches through MultitouchSupport (as other
/// gesture tools do). Trackpads connected after `start` are picked up by the next `start`.
///
/// Every swipe that begins also finishes: with `.ended` or `.cancelled` when the fingers lift, a fourth one
/// joins, frames stop arriving for `staleAfter` (sleep, a trackpad unplugged mid-swipe) or `stop` is called.
public final class SwipeMonitor: @unchecked Sendable {
    public typealias Handler = @Sendable (SwipeRecognizer.Event) -> Void

    public static let shared = SwipeMonitor()

    /// Frames arrive about 100 times a second while fingers touch, moving or not.
    static let staleAfter: TimeInterval = 0.3

    private let lock = NSLock()
    private let watchdogQueue = DispatchQueue(label: "silk.swipe-watchdog")
    private var recognizer = SwipeRecognizer()
    private var handler: Handler?
    /// Events waiting for the main queue; consecutive `.changed` collapse into the latest.
    private var pending: [SwipeRecognizer.Event] = []
    private var isDeliveryScheduled = false
    private var lastFrame: TimeInterval = 0
    private var isWatchdogScheduled = false

    public private(set) var isRunning = false

    /// Starts reporting swipes to `handler` on the main queue. False when no trackpad could be watched.
    @discardableResult
    public func start(_ handler: @escaping Handler) -> Bool {
        let interrupted = lock.withLock {
            let event = recognizer.cancel()
            self.handler = handler
            return event
        }
        if let interrupted { enqueue(interrupted) }
        isRunning = silk_multitouch_start { fingers, x, y in
            SwipeMonitor.shared.touch(fingers: Int(fingers), x: x, y: y)
        }
        return isRunning
    }

    /// Stops watching. A swipe in progress is cancelled, so whatever shows it can go away; that is the last
    /// event the handler gets (no frames arrive after this).
    public func stop() {
        silk_multitouch_stop()
        isRunning = false
        if let interrupted = lock.withLock({ recognizer.cancel() }) { enqueue(interrupted) }
    }

    /// Called on a MultitouchSupport thread for every frame.
    private func touch(fingers: Int, x: Float, y: Float) {
        let (event, startWatchdog): (SwipeRecognizer.Event?, Bool) = lock.withLock {
            lastFrame = ProcessInfo.processInfo.systemUptime
            let event = recognizer.feed(fingers: fingers, x: x, y: y)
            guard recognizer.isActive, !isWatchdogScheduled else { return (event, false) }
            isWatchdogScheduled = true
            return (event, true)
        }
        if let event { enqueue(event) }
        if startWatchdog { scheduleWatchdog() }
    }

    /// While a swipe is tracked, checks that frames keep coming; cancels it when they stop.
    private func scheduleWatchdog() {
        watchdogQueue.asyncAfter(deadline: .now() + Self.staleAfter / 2) { [self] in
            let (event, again): (SwipeRecognizer.Event?, Bool) = lock.withLock {
                guard recognizer.isActive else {
                    isWatchdogScheduled = false
                    return (nil, false)
                }
                guard ProcessInfo.processInfo.systemUptime - lastFrame > Self.staleAfter else { return (nil, true) }
                isWatchdogScheduled = false
                return (recognizer.cancel(), false)
            }
            if let event { enqueue(event) }
            if again { scheduleWatchdog() }
        }
    }

    private func enqueue(_ event: SwipeRecognizer.Event) {
        let schedule: Bool = lock.withLock {
            if case .changed = event, case .changed = pending.last {
                pending[pending.count - 1] = event
            } else {
                pending.append(event)
            }
            guard !isDeliveryScheduled else { return false }
            isDeliveryScheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            let (events, handler) = lock.withLock {
                defer {
                    pending = []
                    isDeliveryScheduled = false
                }
                return (pending, self.handler)
            }
            guard let handler else { return }
            for event in events { handler(event) }
        }
    }
}
