import Foundation

/// Notices app processes that exit without `NSWorkspace.didTerminateApplicationNotification`.
///
/// That notification is not reliable: quitting Find My never posts it, and the app's windows then
/// stayed tracked (keeping their workspace occupied) until Silk restarted. So every app the service
/// cares about is also watched with a kqueue exit source, and ``reap(_:)`` is a backstop for
/// the service's reconcile triggers: a pid with no process behind it counts as exited.
///
/// Each watch reports its pid to `onExit` at most once, by whichever path sees the exit first.
/// The notification may still arrive afterwards; ``claimNotification(_:)`` tells the service to
/// ignore it then. Main thread only.
final class AppExitWatch {
    private let isAlive: (pid_t) -> Bool
    /// Called on main with the pid and the path that saw the exit.
    var onExit: ((pid_t, String) -> Void)?
    private var sources: [pid_t: DispatchSourceProcess] = [:]
    /// Pids reported here whose notification hasn't arrived (yet; for Find My it never does).
    private var reportedWithoutNotification: Set<pid_t> = []

    /// `isAlive` is a test seam for ``reap(_:)``.
    init(isAlive: @escaping (pid_t) -> Bool = AppExitWatch.processExists) {
        self.isAlive = isAlive
    }

    var watched: Set<pid_t> { Set(sources.keys) }

    /// Starts watching `pid`; no-op while it is watched. An exit source on a process that is
    /// already gone fires right away, so an app that quit before this call is still reported.
    func watch(_ pid: pid_t) {
        guard pid > 0, sources[pid] == nil else { return }
        // A new process behind a recycled pid: its own notification must not be swallowed.
        reportedWithoutNotification.remove(pid)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in self?.report(pid, reason: "process exit") }
        sources[pid] = source
        source.resume()
    }

    /// The service ended `pid` by another path: nothing more is reported for it.
    func unwatch(_ pid: pid_t) {
        sources.removeValue(forKey: pid)?.cancel()
    }

    func unwatchAll() {
        for source in sources.values { source.cancel() }
        sources = [:]
        reportedWithoutNotification = []
    }

    /// NSWorkspace reported `pid` terminated. False when this watch already reported the exit.
    func claimNotification(_ pid: pid_t) -> Bool {
        reportedWithoutNotification.remove(pid) == nil
    }

    /// Reports every watched pid in `pids` whose process is gone.
    func reap(_ pids: some Sequence<pid_t>) {
        for pid in pids where sources[pid] != nil && !isAlive(pid) {
            report(pid, reason: "reap: no such process")
        }
    }

    private func report(_ pid: pid_t, reason: String) {
        guard let source = sources.removeValue(forKey: pid) else { return }
        source.cancel()
        reportedWithoutNotification.insert(pid)
        onExit?(pid, reason)
    }

    /// Only `ESRCH` means gone: `EPERM` is a live process we may not signal.
    static func processExists(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno != ESRCH)
    }
}
