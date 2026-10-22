import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import SilkPlatform

/// Waits (on main, so main-queue blocks keep running) until `condition` holds or ~2 s pass.
@MainActor
private func eventually(_ condition: () -> Bool) async {
    for _ in 0 ..< 200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// Lets anything still queued on main (exit sources, worker events) arrive.
@MainActor
private func settle() async {
    try? await Task.sleep(for: .milliseconds(200))
}

private func spawnSleeper() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    return process
}

/// Real exit sources on child processes; `reap` with a fake liveness check.
@MainActor
struct AppExitWatchTests {
    @Test func exitSourceReportsAProcessThatQuitsOnce() async throws {
        let child = try spawnSleeper()
        let watch = AppExitWatch()
        var reports: [String] = []
        watch.onExit = { pid, reason in if pid == child.processIdentifier { reports.append(reason) } }
        watch.watch(child.processIdentifier)
        child.terminate()
        await eventually { !reports.isEmpty }
        watch.reap([child.processIdentifier])
        await settle()
        #expect(reports == ["process exit"])
        #expect(!watch.watched.contains(child.processIdentifier))
        // Its notification, if macOS posts one at all, was handled by the exit.
        #expect(!watch.claimNotification(child.processIdentifier))
    }

    @Test func watchingAProcessThatAlreadyExitedReportsIt() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        let watch = AppExitWatch()
        var reported: [pid_t] = []
        watch.onExit = { pid, _ in reported.append(pid) }
        watch.watch(child.processIdentifier)
        await eventually { !reported.isEmpty }
        #expect(reported == [child.processIdentifier])
    }

    @Test func notificationFirstSilencesTheExitSource() async throws {
        let child = try spawnSleeper()
        let watch = AppExitWatch()
        var reported: [pid_t] = []
        watch.onExit = { pid, _ in reported.append(pid) }
        watch.watch(child.processIdentifier)
        #expect(watch.claimNotification(child.processIdentifier))
        watch.unwatch(child.processIdentifier)  // what the service does once it handled the notification
        child.terminate()
        child.waitUntilExit()
        await settle()
        #expect(reported.isEmpty)
    }

    @Test func reapReportsOnlyWatchedProcessesThatAreGone() async throws {
        let child = try spawnSleeper()
        defer { child.terminate() }
        var dead: Set<pid_t> = []
        let watch = AppExitWatch(isAlive: { !dead.contains($0) })
        var reports: [pid_t: [String]] = [:]
        watch.onExit = { pid, reason in reports[pid, default: []].append(reason) }
        let unwatched: pid_t = 99_999
        watch.watch(getpid())
        watch.watch(child.processIdentifier)
        dead = [child.processIdentifier, unwatched]

        watch.reap([getpid(), child.processIdentifier, unwatched])
        watch.reap([getpid(), child.processIdentifier, unwatched])
        child.terminate()
        child.waitUntilExit()
        await settle()
        #expect(reports == [child.processIdentifier: ["reap: no such process"]])
        #expect(watch.watched == [getpid()])
    }

    @Test func aRecycledPidGetsItsNotificationBack() {
        var dead = true
        let watch = AppExitWatch(isAlive: { _ in !dead })
        watch.watch(getpid())
        watch.reap([getpid()])
        // The pid's new process (a new app launch) is watched afresh; its notification counts.
        dead = false
        watch.watch(getpid())
        #expect(watch.claimNotification(getpid()))
        watch.unwatchAll()
    }

    @Test func processExistsIsFalseOnlyForMissingProcesses() throws {
        #expect(AppExitWatch.processExists(getpid()))
        #expect(AppExitWatch.processExists(1))  // launchd: EPERM, still alive
        #expect(!AppExitWatch.processExists(-1))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        #expect(!AppExitWatch.processExists(child.processIdentifier))
    }
}

/// The service's termination path. The "app" is a `sleep` child process: its worker gets fake
/// windows (as in ``ScreenLockDestroyTests``), and killing it is an exit macOS sends no
/// `didTerminateApplication` notification for, like quitting Find My. `dead` fakes the reaper's
/// liveness check.
@MainActor
private final class ServiceHarness {
    var dead: Set<pid_t> = []
    var events: [PlatformEvent] = []
    let service: PlatformService
    let app: Process
    var pid: pid_t { app.processIdentifier }

    init(locked: Bool = false) throws {
        app = try spawnSleeper()
        var isDead: (pid_t) -> Bool = { _ in false }
        service = PlatformService(focusBackend: .appKit, isProcessAlive: { !isDead($0) })
        isDead = { [unowned self] in dead.contains($0) }
        service.screenLock.isLocked = locked
        service.onEvent = { [unowned self] in events.append($0) }
    }

    deinit { app.terminate() }

    /// Starts the app's worker and tracks fake windows in it.
    func startWorker(windows ids: [UInt32]) async {
        await trackFakeWindows(ids, in: service.startWorker(.current, pid: pid))
    }

    func quit() async {
        app.terminate()
        app.waitUntilExit()
    }

    var destroyed: [UInt32] {
        events.compactMap { if case .windowDestroyed(let id) = $0 { id } else { nil } }
    }

    var terminated: [pid_t] {
        events.compactMap { if case .appTerminated(let pid) = $0 { pid } else { nil } }
    }

    var endsWithAppTerminated: Bool {
        if case .appTerminated = events.last { true } else { false }
    }
}

/// Tracks fake windows on the worker thread: fully subscribed and on screen, so no reconcile
/// timer is armed. Not main-actor isolated: the block runs on the worker's thread.
private func trackFakeWindows(_ ids: [UInt32], in worker: AppWorker) async {
    await withCheckedContinuation { continuation in
        worker.perform {
            for id in ids {
                let snapshot = WindowSnapshot(
                    id: id, pid: worker.pid, bundleId: nil, appName: nil, title: "", frame: nil, kind: .window,
                    isMinimized: false, isFullscreen: false, isFocused: false, isMain: false, level: 0,
                    createdDuringMouseDrag: false, subrole: nil, identifier: nil
                )
                worker.trackingCounter += 1
                let window = TrackedWindow(
                    id: id, element: AXUIElementCreateApplication(worker.pid), trackingOrder: worker.trackingCounter,
                    snapshot: snapshot, dump: AXWindowDump()
                )
                window.subscribed = Set(TrackedWindow.notifications)
                worker.windows[id] = window
            }
            continuation.resume()
        }
    }
}

@MainActor
struct AppTerminationTests {
    @Test func exitWithoutNotificationDestroysWindowsAndTerminatesOnce() async throws {
        let harness = try ServiceHarness()
        await harness.startWorker(windows: [11, 12])

        await harness.quit()
        await eventually { !harness.terminated.isEmpty }
        // A late notification and later reaps are no-ops.
        harness.service.workspaceDidTerminate(harness.pid)
        harness.dead = [harness.pid]
        harness.service.reapExitedApps()
        await settle()

        #expect(harness.destroyed.sorted() == [11, 12])
        #expect(harness.terminated == [harness.pid])
        #expect(harness.endsWithAppTerminated)  // after the windows' destroys, as the engine expects
        #expect(harness.service.workers[harness.pid] == nil)
    }

    @Test func reapCatchesAnExitNobodyReported() async throws {
        let harness = try ServiceHarness()
        await harness.startWorker(windows: [21])

        harness.dead = [harness.pid]
        harness.service.reapExitedApps()
        await eventually { !harness.terminated.isEmpty }
        await harness.quit()
        harness.service.workspaceDidTerminate(harness.pid)
        await settle()

        #expect(harness.destroyed == [21])
        #expect(harness.terminated == [harness.pid])
        #expect(harness.endsWithAppTerminated)
    }

    @Test func notificationFirstThenExitTerminatesOnce() async throws {
        let harness = try ServiceHarness()
        await harness.startWorker(windows: [31])

        harness.service.workspaceDidTerminate(harness.pid)
        await eventually { !harness.terminated.isEmpty }
        await harness.quit()
        harness.dead = [harness.pid]
        harness.service.reapExitedApps()
        await settle()

        #expect(harness.destroyed == [31])
        #expect(harness.terminated == [harness.pid])
        #expect(harness.endsWithAppTerminated)
    }

    @Test func exitWhileLockedStillDestroysWindows() async throws {
        let harness = try ServiceHarness(locked: true)
        await harness.startWorker(windows: [41])

        await harness.quit()
        await eventually { !harness.terminated.isEmpty }

        #expect(harness.destroyed == [41])
        #expect(harness.terminated == [harness.pid])
    }

    @Test func liveAppsAreNotReaped() async throws {
        let harness = try ServiceHarness()
        await harness.startWorker(windows: [51])
        harness.service.reapExitedApps()
        await settle()
        #expect(harness.destroyed.isEmpty)
        #expect(harness.terminated.isEmpty)
        #expect(harness.service.workers[harness.pid] != nil)
        harness.service.stop()
    }

    /// `NSWorkspace` may keep listing an app that quit unnoticed; no worker (and so no window
    /// detection) may start for it.
    @Test func appsWithoutAProcessAreNotTracked() throws {
        let harness = try ServiceHarness()
        let app = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != getpid() && $0.bundleIdentifier != PlatformService.lockScreenBundleId && !$0.isTerminated
        })
        #expect(harness.service.shouldTrack(app))
        harness.dead = [app.processIdentifier]
        #expect(!harness.service.shouldTrack(app))
    }
}
