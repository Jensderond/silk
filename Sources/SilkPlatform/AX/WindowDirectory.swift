import Foundation
import os

/// Thread-safe map from window id to the worker that owns the window's AX element.
/// Workers register windows as soon as they track them, so actions and frame writes can
/// be routed before the engine has even seen the `windowAppeared` event.
final class WindowDirectory: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(uncheckedState: [UInt32: AppWorker]())

    func register(_ window: UInt32, _ worker: AppWorker) {
        lock.withLockUnchecked { $0[window] = worker }
    }

    func unregister(_ window: UInt32) {
        lock.withLockUnchecked { _ = $0.removeValue(forKey: window) }
    }

    func worker(for window: UInt32) -> AppWorker? {
        lock.withLockUnchecked { $0[window] }
    }
}
