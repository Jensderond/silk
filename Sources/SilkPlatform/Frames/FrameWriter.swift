import CoreGraphics
import Dispatch
import Foundation
import os

/// The thread that owns a window's AX element and performs writes to it (an app worker in
/// production, a fake in tests).
protocol FrameWriteTarget: AnyObject {
    var pid: pid_t { get }
    /// Runs `drain` asynchronously on the target's thread. Returns false when the target was torn
    /// down and will never run it.
    func scheduleDrain(_ drain: @escaping () -> Void) -> Bool
    /// Performs writes; called on the target's thread from within a drain.
    func performFrameWrites(_ writes: [FrameWrite])
    /// Writes `frames` as final frames on the target's thread, then calls `completion` with
    /// the windows that were written. Used for the termination restore.
    func performBlockingRestore(_ frames: [(UInt32, CGRect)], completion: @escaping (Set<UInt32>) -> Void)
}

enum FrameWriteAttribute {
    case position, size
}

/// Thread-safe entry point for frame writes (used from the animator thread).
///
/// Per window at most one write is pending: a newer submission replaces the pending one
/// (latest wins), and the window's app worker drains whatever is pending when it gets to it,
/// so a slow app never accumulates a backlog of stale animation ticks. Writes whose epoch is
/// older than the newest epoch seen for that window are dropped.
public final class FrameWriter: @unchecked Sendable {
    private struct PendingBatch {
        let target: FrameWriteTarget
        var order: [UInt32] = []
        var writes: [UInt32: FrameWrite] = [:]
    }

    private struct State {
        var pending: [ObjectIdentifier: PendingBatch] = [:]
        var latestEpoch: [UInt32: UInt64] = [:]
        /// Newest epoch accepted for any window (plan epochs are global and monotonic).
        var newestEpoch: UInt64 = 0
        var stats: [pid_t: WriteLatencyStats] = [:]

        mutating func dropPending(window: UInt32, target: FrameWriteTarget) {
            let key = ObjectIdentifier(target)
            guard var batch = pending[key], batch.writes.removeValue(forKey: window) != nil else { return }
            batch.order.removeAll { $0 == window }
            pending[key] = batch
        }
    }

    private let lock = OSAllocatedUnfairLock(uncheckedState: State())
    private let resolveTarget: (UInt32) -> FrameWriteTarget?

    init(resolveTarget: @escaping (UInt32) -> FrameWriteTarget?) {
        self.resolveTarget = resolveTarget
    }

    /// Queues writes. Writes for unknown windows and writes with a stale epoch are dropped.
    public func submit(_ writes: [FrameWrite]) {
        var targetsToSchedule: [FrameWriteTarget] = []
        let resolved = writes.map { ($0, resolveTarget($0.window)) }
        lock.withLockUnchecked { state in
            for (write, target) in resolved {
                guard let target else { continue }
                if let latest = state.latestEpoch[write.window], write.epoch < latest { continue }
                state.latestEpoch[write.window] = write.epoch
                state.newestEpoch = max(state.newestEpoch, write.epoch)
                let key = ObjectIdentifier(target)
                // A batch exists exactly while a drain is scheduled for its target.
                if state.pending[key] == nil { targetsToSchedule.append(target) }
                var batch = state.pending[key] ?? PendingBatch(target: target)
                if batch.writes.updateValue(write, forKey: write.window) == nil { batch.order.append(write.window) }
                state.pending[key] = batch
            }
        }
        for target in targetsToSchedule {
            let scheduled = target.scheduleDrain { [weak self, weak target] in
                guard let self, let target else { return }
                self.drain(target)
            }
            // A torn-down target never drains: drop its batch, or it would pin the target forever
            // and swallow every later submission for it.
            if !scheduled { lock.withLockUnchecked { _ = $0.pending.removeValue(forKey: ObjectIdentifier(target)) } }
        }
    }

    /// Drops the pending write for `window`, if any.
    public func cancel(window: UInt32) {
        guard let target = resolveTarget(window) else { return }
        lock.withLockUnchecked { $0.dropPending(window: window, target: target) }
    }

    /// Measured write cost for the window's app.
    public func cost(window: UInt32) -> WriteCost {
        guard let pid = resolveTarget(window)?.pid else { return .unmeasured }
        let now = MonotonicClock.now()
        return lock.withLockUnchecked { $0.stats[pid]?.cost(at: now) } ?? .unmeasured
    }

    /// Writes final frames synchronously (termination restore): cancels pending writes for those
    /// windows, writes on each app's thread in parallel and waits until all are done or `deadline`
    /// passes. Returns the windows that were written. Must not be called from an app worker thread.
    ///
    /// Afterwards the windows only accept writes of epochs newer than any submitted so far: writes
    /// of current plans arriving late (an animator snapping its tweens while the restore runs, a
    /// deferred park) would otherwise undo the restore.
    @discardableResult
    public func writeSynchronously(_ frames: [(UInt32, CGRect)], deadline: DispatchTime) -> Set<UInt32> {
        var byTarget: [ObjectIdentifier: (FrameWriteTarget, [(UInt32, CGRect)])] = [:]
        for (window, frame) in frames {
            guard let target = resolveTarget(window) else { continue }
            byTarget[ObjectIdentifier(target), default: (target, [])].1.append((window, frame))
        }
        lock.withLockUnchecked { state in
            let fence = state.newestEpoch &+ 1
            for (target, targetFrames) in byTarget.values {
                for (window, _) in targetFrames {
                    state.dropPending(window: window, target: target)
                    state.latestEpoch[window] = fence
                }
            }
        }
        let written = OSAllocatedUnfairLock(initialState: Set<UInt32>())
        let group = DispatchGroup()
        for (target, targetFrames) in byTarget.values {
            group.enter()
            target.performBlockingRestore(targetFrames) { done in
                written.withLock { $0.formUnion(done) }
                group.leave()
            }
        }
        _ = group.wait(timeout: deadline)
        return written.withLock { $0 }
    }

    // MARK: - Worker side

    func drain(_ target: FrameWriteTarget) {
        let writes: [FrameWrite] = lock.withLockUnchecked { state in
            guard let batch = state.pending.removeValue(forKey: ObjectIdentifier(target)) else { return [] }
            return batch.order.compactMap { batch.writes[$0] }
        }
        if !writes.isEmpty { target.performFrameWrites(writes) }
    }

    func recordLatency(pid: pid_t, attribute: FrameWriteAttribute, milliseconds: Double, timedOut: Bool) {
        let now = MonotonicClock.now()
        lock.withLockUnchecked { state in
            var stats = state.stats[pid] ?? WriteLatencyStats()
            if timedOut {
                stats.recordTimeout(at: now)
            } else {
                switch attribute {
                    case .position: stats.recordPosition(ms: milliseconds)
                    case .size: stats.recordSize(ms: milliseconds)
                }
            }
            state.stats[pid] = stats
        }
    }

    /// Forgets a destroyed window: pending write and epoch.
    func forget(window: UInt32, target: FrameWriteTarget) {
        lock.withLockUnchecked { state in
            state.latestEpoch.removeValue(forKey: window)
            state.dropPending(window: window, target: target)
        }
    }

    /// Forgets a torn-down target: its pending writes (whose drain will never run) and its app's latency stats.
    func forget(target: FrameWriteTarget) {
        lock.withLockUnchecked { state in
            state.pending.removeValue(forKey: ObjectIdentifier(target))
            state.stats.removeValue(forKey: target.pid)
        }
    }
}
