import CoreGraphics
import Foundation
import os

/// Whether the login window covers the session. While locked, apps answer AX queries with their
/// application element in place of every window (`kAXWindows` lists N copies of the app, the
/// focused window *is* the app), so reconciliation would wrongly order out or destroy every
/// window. Workers skip it until the unlock reconciliation.
final class ScreenLockState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: ScreenLockState.querySession())

    var isLocked: Bool {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }

    static func querySession() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }
}
