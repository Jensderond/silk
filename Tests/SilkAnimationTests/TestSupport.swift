import CoreGraphics
import Foundation
@testable import SilkAnimation

let display: CGDirectDisplayID = 1
let frameInterval60 = 1.0 / 60

/// Linear-curve settings make expected frames easy to reason about.
func settings(curve: MotionCurve = .linear, duration: TimeInterval = 0.2) -> AnimationSettings {
    AnimationSettings(duration: duration, workspaceDuration: duration, curve: curve)
}

func move(
    _ window: UInt32 = 1, pid: pid_t = 100, from: CGRect, to: CGRect,
    kind: AnimationRequest.Move.Kind = .layout, then: CGRect? = nil
) -> AnimationRequest.Move {
    AnimationRequest.Move(window: window, pid: pid, from: from, to: to, kind: kind, displayID: display, then: then)
}

/// Drives a scheduler at 60 Hz from `start` until it is idle (or `maxTicks`), collecting outputs.
struct Run {
    var scheduler: AnimationScheduler
    var now: Double = 0
    var costs: [UInt32: WriteCost] = [:]

    init(_ settings: AnimationSettings) {
        scheduler = AnimationScheduler(settings: settings)
    }

    mutating func apply(_ moves: [AnimationRequest.Move], epoch: UInt64 = 1, snaps: [AnimationRequest.Snap] = []) -> SchedulerOutput {
        let costs = self.costs
        return scheduler.apply(
            AnimationRequest(epoch: epoch, moves: moves, snaps: snaps), now: now,
            cost: { costs[$0] ?? .unmeasured }
        )
    }

    mutating func tick(interval: Double = frameInterval60) -> SchedulerOutput {
        now += interval
        let costs = self.costs
        return scheduler.tick(display: display, now: now, frameInterval: interval, cost: { costs[$0] ?? .unmeasured })
    }

    /// A tick of a 60 Hz display whose target time is `elapsed` after the previous `now`.
    mutating func tick(elapsed: Double) -> SchedulerOutput {
        now += elapsed
        let costs = self.costs
        return scheduler.tick(display: display, now: now, frameInterval: frameInterval60, cost: { costs[$0] ?? .unmeasured })
    }

    /// The animator's lead-in: the new tweens' frame for the vsync one `interval` from now.
    mutating func leadIn(interval: Double = frameInterval60) -> SchedulerOutput {
        let costs = self.costs
        return scheduler.leadIn(display: display, now: now + interval, frameInterval: interval, cost: { costs[$0] ?? .unmeasured })
    }

    mutating func runToEnd(maxTicks: Int = 600) -> [SchedulerOutput] {
        var outputs: [SchedulerOutput] = []
        for _ in 0..<maxTicks where !scheduler.isIdle {
            outputs.append(tick())
        }
        return outputs
    }
}

extension FrameWrite.Mode {
    var setsSize: Bool {
        switch self {
        case .final: true
        case .intermediate(let setSize, _): setSize
        }
    }

    var sizeFirst: Bool {
        if case .intermediate(_, let sizeFirst) = self { return sizeFirst }
        return false
    }
}

/// Thread-safe recording sink for Animator tests.
final class RecordingSink: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [FrameWrite] = []
    var writes: [FrameWrite] { lock.withLock { recorded } }

    func submit(_ writes: [FrameWrite]) { lock.withLock { recorded += writes } }
    func cost(window: UInt32) -> WriteCost { .unmeasured }
}
