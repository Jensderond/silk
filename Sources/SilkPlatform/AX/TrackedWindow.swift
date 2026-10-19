import ApplicationServices
import Foundation

/// A window a worker tracks. Confined to its worker thread.
final class TrackedWindow {
    static let notifications = [
        kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification,
    ]

    let id: UInt32
    let element: AXUIElement
    /// Monotonic per worker; teardown releases windows in reverse order.
    let trackingOrder: Int
    var subscribed: Set<String> = []
    var snapshot: WindowSnapshot
    var dump: AXWindowDump
    var isOrderedOut = false
    var echo = EchoRing()
    var lastReclassification: TimeInterval = 0
    /// Why the window looked destroyed while the screen was locked; non-nil until the first
    /// reconciliation after unlock re-checks it.
    var deferredDestroyReason: String?

    init(id: UInt32, element: AXUIElement, trackingOrder: Int, snapshot: WindowSnapshot, dump: AXWindowDump) {
        self.id = id
        self.element = element
        self.trackingOrder = trackingOrder
        self.snapshot = snapshot
        self.dump = dump
    }

    var isFullySubscribed: Bool { subscribed.count == Self.notifications.count }
}
