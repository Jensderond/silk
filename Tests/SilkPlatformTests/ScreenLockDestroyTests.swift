import ApplicationServices
import AppKit
import os
import Testing
@testable import SilkPlatform

/// A real worker for the test process itself, with injected windows whose element is a stand-in.
/// The paths under test decide from the lock state and the notification, not from AX reads, so
/// they behave the same with or without Accessibility permission.
private final class WorkerHarness {
    let screenLock = ScreenLockState()
    let worker: AppWorker
    private let events = OSAllocatedUnfairLock(uncheckedState: [PlatformEvent]())

    init(locked: Bool) {
        screenLock.isLocked = locked
        let environment = AppWorkerEnvironment(
            directory: WindowDirectory(), writer: FrameWriter(resolveTarget: { _ in nil }), screenLock: screenLock
        ) { [events] event in events.withLockUnchecked { $0.append(event) } }
        worker = AppWorker(app: .current, environment: environment, initialEnumeration: nil)
    }

    deinit { worker.stop(emitDestroyed: false) }

    var destroyed: [UInt32] {
        events.withLockUnchecked { $0.compactMap { if case .windowDestroyed(let id) = $0 { id } else { nil } } }
    }

    /// Runs `body` on the worker thread and waits for it.
    func run<T>(_ body: @escaping (AppWorker) -> T) async -> T {
        await withCheckedContinuation { continuation in
            let worker = worker
            worker.perform { continuation.resume(returning: body(worker)) }
        }
    }

    /// Tracks a fake window: fully subscribed and on screen, so no reconcile timer is armed.
    func track(_ id: UInt32, element: AXUIElement = AXUIElementCreateApplication(getpid())) async {
        await run { worker in
            let snapshot = WindowSnapshot(
                id: id, pid: getpid(), bundleId: nil, appName: nil, title: "", frame: nil, kind: .window,
                isMinimized: false, isFullscreen: false, isFocused: false, isMain: false, level: 0,
                createdDuringMouseDrag: false, subrole: nil, identifier: nil
            )
            worker.trackingCounter += 1
            let window = TrackedWindow(id: id, element: element, trackingOrder: worker.trackingCounter, snapshot: snapshot, dump: AXWindowDump())
            window.subscribed = Set(TrackedWindow.notifications)
            worker.windows[id] = window
        }
    }

    func notifyDestroyed(_ id: UInt32) async {
        await run { $0.handleNotification(kAXUIElementDestroyedNotification, element: AXUIElementCreateApplication(getpid()), windowID: id) }
    }

    func deferredReason(_ id: UInt32) async -> String?? {
        await run { worker in worker.windows[id].map(\.deferredDestroyReason) }
    }
}

struct ScreenLockDestroyTests {
    @Test func destroyedNotificationWhileUnlockedDestroysImmediately() async {
        let harness = WorkerHarness(locked: false)
        await harness.track(7)
        await harness.notifyDestroyed(7)
        #expect(harness.destroyed == [7])
        #expect(await harness.deferredReason(7) == .none)
    }

    @Test func destroyedNotificationWhileLockedIsDeferred() async {
        let harness = WorkerHarness(locked: true)
        await harness.track(7)
        await harness.notifyDestroyed(7)
        await harness.notifyDestroyed(7)
        #expect(harness.destroyed.isEmpty)
        #expect(await harness.deferredReason(7) == .some("kAXUIElementDestroyed notification"))
    }

    @Test func unlockRecheckDestroysOnlyWindowsStillInvalid() async {
        let harness = WorkerHarness(locked: true)
        let closedDuringLock = AXUIElementCreateSystemWide()
        await harness.track(1, element: closedDuringLock)
        await harness.track(2)
        await harness.notifyDestroyed(1)
        await harness.notifyDestroyed(2)

        // Still locked: the re-check waits for unlock.
        await harness.run { $0.revalidateDeferredDestroys(isGone: { _ in true }) }
        #expect(harness.destroyed.isEmpty)

        harness.screenLock.isLocked = false
        await harness.run { $0.revalidateDeferredDestroys(isGone: { CFEqual($0, closedDuringLock) }) }
        #expect(harness.destroyed == [1])
        #expect(await harness.deferredReason(1) == .none)
        #expect(await harness.deferredReason(2) == .some(nil))
    }

    @Test func appTerminationStillDestroysWhileLocked() async {
        let harness = WorkerHarness(locked: true)
        await harness.track(3)
        await withCheckedContinuation { continuation in
            harness.worker.stop(emitDestroyed: true) { continuation.resume() }
        }
        #expect(harness.destroyed == [3])
    }
}
