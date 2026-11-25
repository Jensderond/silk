import Foundation
import SilkPrivateAPI

/// Watches every trackpad for three-finger horizontal swipes, system-wide. macOS only delivers such
/// gestures to the frontmost app, so this reads raw touches through MultitouchSupport (as other
/// gesture tools do). Trackpads connected after `start` are picked up by the next `start`.
public final class SwipeMonitor: @unchecked Sendable {
    public static let shared = SwipeMonitor()

    private let lock = NSLock()
    private var recognizer = SwipeRecognizer()
    private var handler: (@Sendable (SwipeRecognizer.Direction) -> Void)?

    public private(set) var isRunning = false

    /// Starts reporting swipes to `handler` on the main queue. False when no trackpad could be watched.
    @discardableResult
    public func start(_ handler: @escaping @Sendable (SwipeRecognizer.Direction) -> Void) -> Bool {
        lock.withLock {
            self.handler = handler
            recognizer = SwipeRecognizer()
        }
        isRunning = silk_multitouch_start { fingers, x, y in
            SwipeMonitor.shared.touch(fingers: Int(fingers), x: x, y: y)
        }
        return isRunning
    }

    public func stop() {
        silk_multitouch_stop()
        isRunning = false
        lock.withLock { handler = nil }
    }

    /// Called on a MultitouchSupport thread for every frame.
    private func touch(fingers: Int, x: Float, y: Float) {
        let swipe: (SwipeRecognizer.Direction, @Sendable (SwipeRecognizer.Direction) -> Void)? = lock.withLock {
            guard let direction = recognizer.feed(fingers: fingers, x: x, y: y), let handler else { return nil }
            return (direction, handler)
        }
        if let (direction, handler) = swipe {
            DispatchQueue.main.async { handler(direction) }
        }
    }
}
