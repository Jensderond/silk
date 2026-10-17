import ApplicationServices
import Dispatch
import os

/// Final-frame writes for windows no app worker tracks yet: the startup recovery of windows a
/// previous run left parked happens before any worker exists. Each app gets a short-lived app
/// element, created, used and released on one thread; apps are written in parallel.
enum UntrackedFrameRestore {
    /// Blocks the calling thread until every app answered (or timed out). Returns the windows written.
    static func write(_ frames: [(UInt32, CGRect)]) -> Set<UInt32> {
        let owners = WindowServerInfo.describe(frames.map(\.0))
        var byPID: [pid_t: [UInt32: CGRect]] = [:]
        for (window, frame) in frames {
            guard let pid = owners[window]?.ownerPID else { continue }
            byPID[pid, default: [:]][window] = frame
        }
        let apps = Array(byPID)
        let written = OSAllocatedUnfairLock(initialState: Set<UInt32>())
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            let done = write(apps[index].value, pid: apps[index].key)
            written.withLock { $0.formUnion(done) }
        }
        return written.withLock { $0 }
    }

    private static func write(_ frames: [UInt32: CGRect], pid: pid_t) -> Set<UInt32> {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axMessagingTimeout)
        var written = Set<UInt32>()
        for element in app.elements(kAXWindowsAttribute).elements {
            guard let window = element.windowID, let frame = frames[window] else { continue }
            AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
            // `size, position, size` like every final write (see `AppWorker.writeFinal`).
            if element.setSize(frame.size) != .invalidUIElement,
               element.setPosition(frame.origin) != .invalidUIElement,
               element.setSize(frame.size) != .invalidUIElement {
                written.insert(window)
            }
        }
        return written
    }
}
