import CoreGraphics
import Foundation

/// What one scheduler step produced.
public struct SchedulerOutput: Equatable, Sendable {
    /// At most one write per window. Deterministic order: completions first, then
    /// intermediate writes grouped by app (ascending pid, then window ID).
    public var writes: [FrameWrite] = []
    public var completions: [AnimationCompletion] = []
    /// Apps that started animating / have no animating window left (ascending pid).
    public var appsBegan: [pid_t] = []
    public var appsEnded: [pid_t] = []

    public init() {}

    public var isEmpty: Bool { writes.isEmpty && completions.isEmpty && appsBegan.isEmpty && appsEnded.isEmpty }

    mutating func finish(window: UInt32, at frame: CGRect, epoch: UInt64) {
        writes.append(FrameWrite(window: window, frame: frame, epoch: epoch, mode: .final))
        completions.append(AnimationCompletion(window: window, epoch: epoch))
    }
}

/// The deterministic core of the animator: tweens in, frame writes out. No threads, no
/// display links, no clock — callers pass `now` (seconds, any monotonic base) and a cost
/// lookup, so every rule is unit-testable. Not thread-safe; `Animator` confines it to its
/// thread.
///
/// Rules (docs/ARCHITECTURE.md, "Animation rules"):
/// * A move for an animating window retargets from its presented frame; springs keep velocity.
/// * Per app and tick the write budget is one frame interval of the ticking display. Every
///   tick writes positions; sizes are written every n-th tick, n = ceil(k · Σ sizeLatency /
///   (frameInterval − Σ positionLatency)). n > `maxSizeCadence` → position-only: dimensions
///   that shrink are set at once, dimensions that grow only by the final write.
/// * Size latency > `snapLatencyMs` (for tweens that resize), position latency above it, or a
///   recent timeout → the window snaps (final write now).
/// * Intermediate writes order size before position when shrinking, after when growing.
/// * Overshoot moves the position only; sizes are clamped between start and target.
/// * Moves smaller than `minimumDelta` snap; once a tween's time is up the final write is
///   always emitted, whatever the budget did.
/// * New tweens are written at once by `leadIn` (their frame for the coming vsync) and re-phased
///   by their first tick, so they start in phase with vsync; `apply` never steps running tweens.
public struct AnimationScheduler {
    public var settings: AnimationSettings
    /// The system "Reduce motion" setting; snaps everything when `settings.respectReduceMotion`.
    public var reduceMotion = false

    private(set) var tweens: [UInt32: Tween] = [:]

    public init(settings: AnimationSettings) {
        self.settings = settings
    }

    /// True when new moves are applied as snaps (animations off, or reduce motion respected).
    public var isSnapping: Bool { !settings.isEnabled || (settings.respectReduceMotion && reduceMotion) }

    public var isIdle: Bool { tweens.isEmpty }

    public var animatingWindows: [UInt32] { tweens.keys.sorted() }

    /// Displays that have at least one tween, i.e. whose display link must run.
    public var activeDisplays: Set<CGDirectDisplayID> { Set(tweens.values.map(\.displayID)) }

    public func hasTweens(on displayID: CGDirectDisplayID) -> Bool {
        tweens.values.contains { $0.displayID == displayID }
    }

    /// Earliest time at which some tween is due to complete.
    public var nextDeadline: Double? { tweens.values.map(\.end).min() }

    /// The frame last written to an animating window (or its start frame before the first
    /// tick); nil when the window is not animating.
    public func presentedFrame(window: UInt32) -> CGRect? { tweens[window]?.written }

    // MARK: Mutations

    /// Starts, retargets or snaps the request's windows. Snaps are applied before moves.
    public mutating func apply(
        _ request: AnimationRequest, now: Double, cost: (UInt32) -> WriteCost
    ) -> SchedulerOutput {
        let appsBefore = animatingApps
        var output = SchedulerOutput()
        for snap in request.snaps {
            tweens[snap.window] = nil
            output.finish(window: snap.window, at: snap.frame, epoch: request.epoch)
        }
        for move in request.moves {
            apply(move, epoch: request.epoch, now: now, cost: cost(move.window), into: &output)
        }
        recordAppChanges(since: appsBefore, into: &output)
        return output
    }

    /// Advances every tween driven by `displayID` to `now` (the display's target presentation
    /// time) with a budget of `frameInterval` seconds per app.
    public mutating func tick(
        display displayID: CGDirectDisplayID, now: Double, frameInterval: Double,
        cost: (UInt32) -> WriteCost
    ) -> SchedulerOutput {
        advance(display: displayID, now: now, frameInterval: frameInterval, cost: cost, leadIn: false)
    }

    /// Writes the first frame of the tweens on `displayID` that were never stepped (started or
    /// retargeted by the last `apply`), sampled at `now`: the presentation time of the coming
    /// vsync. Running tweens are left alone; their frame for that vsync is already out, and a
    /// sample at another time would knock them off the vsync grid or even step them backwards.
    ///
    /// The first `tick` after a lead-in re-phases these tweens so they advance exactly
    /// `frameInterval` past the lead-in frame, whatever that tick's `now`: a tween then shows
    /// curve times 1, 2, 3… frames on consecutive vsyncs however its request was timed, instead
    /// of skipping up to a frame of motion at the start, where ease-out curves move fastest.
    public mutating func leadIn(
        display displayID: CGDirectDisplayID, now: Double, frameInterval: Double,
        cost: (UInt32) -> WriteCost
    ) -> SchedulerOutput {
        advance(display: displayID, now: now, frameInterval: frameInterval, cost: cost, leadIn: true)
    }

    /// Completes tweens that are more than `grace` seconds past their deadline. Safety net
    /// for display links that stop firing (display asleep, screen removed).
    public mutating func finishOverdue(now: Double, grace: Double) -> SchedulerOutput {
        let appsBefore = animatingApps
        var output = SchedulerOutput()
        for window in tweens.keys.sorted() where now >= tweens[window]!.end + grace {
            finish(window, into: &output)
        }
        recordAppChanges(since: appsBefore, into: &output)
        return output
    }

    /// Completes every tween immediately (final writes to resting frames).
    public mutating func snapAll() -> SchedulerOutput {
        let appsBefore = animatingApps
        var output = SchedulerOutput()
        for window in tweens.keys.sorted() {
            finish(window, into: &output)
        }
        recordAppChanges(since: appsBefore, into: &output)
        return output
    }

    /// Drops a window's tween without any write (window destroyed or grabbed by the user).
    public mutating func cancel(window: UInt32) -> SchedulerOutput {
        let appsBefore = animatingApps
        var output = SchedulerOutput()
        tweens[window] = nil
        recordAppChanges(since: appsBefore, into: &output)
        return output
    }

    /// Moves tweens driven by displays not in `available` to `fallback`.
    public mutating func reassignDisplays(available: Set<CGDirectDisplayID>, fallback: CGDirectDisplayID) {
        for window in tweens.keys where !available.contains(tweens[window]!.displayID) {
            tweens[window]!.displayID = fallback
        }
    }

    // MARK: Internals

    private var animatingApps: Set<pid_t> { Set(tweens.values.map(\.pid)) }

    private func recordAppChanges(since before: Set<pid_t>, into output: inout SchedulerOutput) {
        let after = animatingApps
        output.appsBegan = after.subtracting(before).sorted()
        output.appsEnded = before.subtracting(after).sorted()
    }

    private mutating func advance(
        display displayID: CGDirectDisplayID, now: Double, frameInterval: Double,
        cost: (UInt32) -> WriteCost, leadIn: Bool
    ) -> SchedulerOutput {
        let appsBefore = animatingApps
        var output = SchedulerOutput()
        var groups: [pid_t: [(window: UInt32, cost: WriteCost)]] = [:]
        for window in tweens.keys.sorted() {
            guard let tween = tweens[window], tween.displayID == displayID else { continue }
            if leadIn {
                guard tween.ticks == 0 else { continue }
            } else if tween.needsAlignment {
                align(window, now: now, frameInterval: frameInterval)
            }
            let writeCost = cost(window)
            if now >= tweens[window]!.end || exceedsBudget(writeCost, resizes: tween.animatesSize) {
                finish(window, into: &output)
            } else {
                groups[tween.pid, default: []].append((window, writeCost))
            }
        }
        for pid in groups.keys.sorted() {
            let members = groups[pid]!
            let cadence = sizeCadence(for: members, frameInterval: frameInterval)
            for member in members {
                step(member.window, now: now, sizeCadence: cadence, into: &output)
                if leadIn { tweens[member.window]?.needsAlignment = true }
            }
        }
        recordAppChanges(since: appsBefore, into: &output)
        return output
    }

    /// Shifts a lead-in tween's timeline so that `now` lies one frame interval after its lead-in
    /// sample. Normally the shift is within one frame (the request's offset from vsync); it is
    /// bounded so a stalled display link cannot postpone a tween by more than a couple of frames.
    private mutating func align(_ window: UInt32, now: Double, frameInterval: Double) {
        guard var tween = tweens[window] else { return }
        tween.needsAlignment = false
        if let last = tween.lastSampleTime {
            let shift = min(max(now - (last + frameInterval), -frameInterval), 2 * frameInterval)
            tween.start += shift
            tween.end += shift
        }
        tweens[window] = tween
    }

    private mutating func finish(_ window: UInt32, into output: inout SchedulerOutput) {
        guard let tween = tweens.removeValue(forKey: window) else { return }
        output.finish(window: window, at: tween.restingFrame, epoch: tween.epoch)
    }

    private func exceedsBudget(_ cost: WriteCost, resizes: Bool) -> Bool {
        let limit = settings.policy.snapLatencyMs
        return cost.recentTimeout || cost.positionLatencyMs > limit || (resizes && cost.sizeLatencyMs > limit)
    }

    private mutating func apply(
        _ move: AnimationRequest.Move, epoch: UInt64, now: Double, cost: WriteCost,
        into output: inout SchedulerOutput
    ) {
        let policy = settings.policy
        let existing = tweens.removeValue(forKey: move.window)
        let current = existing?.written ?? move.from

        var start = current
        if case .open(.popIn) = move.kind, existing == nil, cost.sizeLatencyMs <= policy.popInMaxSizeLatencyMs {
            start = move.to.scaledAroundCenter(by: policy.popInScale)
        }
        let positionOnly: Bool
        switch move.kind {
        case .workspaceIn, .workspaceOut: positionOnly = true
        case .layout, .open: positionOnly = false
        }
        let animatesSize = !positionOnly && start.size.maxDelta(to: move.to.size) >= 0.5
        let duration = positionOnly ? settings.workspaceDuration : settings.duration

        let curve = settings.curve
        let usesDuration: Bool
        if case .spring = curve { usesDuration = false } else { usesDuration = true }

        if isSnapping
            || (usesDuration && duration <= 0)
            || exceedsBudget(cost, resizes: animatesSize)
            || start.maxComponentDelta(to: move.to) < policy.minimumDelta
        {
            output.finish(window: move.window, at: move.restingFrame, epoch: epoch)
            return
        }

        let from = SIMD4<Double>(start), to = SIMD4<Double>(move.to)
        let velocity = existing?.retargetVelocity(at: now) ?? .zero
        let end: Double
        if case .spring(let spring) = curve {
            let settling = spring.settlingTime(displacement: from - to, velocity: velocity)
            guard settling > 0 else {
                output.finish(window: move.window, at: move.restingFrame, epoch: epoch)
                return
            }
            end = now + settling
        } else {
            end = now + duration
        }
        tweens[move.window] = Tween(
            window: move.window, pid: move.pid, displayID: move.displayID, epoch: epoch,
            positionOnly: positionOnly, animatesSize: animatesSize,
            from: from, to: to, restingFrame: move.restingFrame,
            start: now, end: end, curve: curve, initialVelocity: velocity,
            written: current
        )
    }

    /// n for one app's group of tweens this tick; `Int.max` when even positions use up the budget.
    private func sizeCadence(for members: [(window: UInt32, cost: WriteCost)], frameInterval: Double) -> Int {
        let policy = settings.policy
        var positionCost = 0.0, sizeCost = 0.0
        for member in members {
            positionCost += max(member.cost.positionLatencyMs, policy.minimumPositionCostMs)
            if tweens[member.window]!.animatesSize { sizeCost += member.cost.sizeLatencyMs }
        }
        guard sizeCost > 0 else { return 1 }
        let available = frameInterval * 1000 - positionCost
        guard available > 0 else { return .max }
        let cadence = (policy.sizeCadenceFactor * sizeCost / available).rounded(.up)
        return cadence >= Double(Int.max / 2) ? .max : max(1, Int(cadence))
    }

    private mutating func step(_ window: UInt32, now: Double, sizeCadence: Int, into output: inout SchedulerOutput) {
        guard var tween = tweens[window] else { return }
        let value = tween.sample(at: now).value
        let writtenSize = SIMD2(Double(tween.written.width), Double(tween.written.height))

        let size: SIMD2<Double>
        if tween.positionOnly {
            size = tween.targetSize
        } else if !tween.animatesSize {
            size = writtenSize
        } else if sizeCadence > settings.policy.maxSizeCadence {
            size = pointwiseMin(writtenSize, tween.targetSize)
        } else if tween.ticks % sizeCadence == 0 {
            size = pointwiseMin(pointwiseMax(SIMD2(value[2], value[3]), tween.sizeLowerBound), tween.sizeUpperBound)
        } else {
            size = writtenSize
        }
        let frame = CGRect(
            x: value[0].rounded(), y: value[1].rounded(),
            width: size.x.rounded(), height: size.y.rounded()
        )
        tween.ticks += 1
        tween.lastSampleTime = now
        let setSize = frame.size.maxDelta(to: tween.written.size) >= 0.5
        let moved = abs(frame.minX - tween.written.minX) >= 0.5 || abs(frame.minY - tween.written.minY) >= 0.5
        if setSize || moved {
            let shrinking = frame.width * frame.height < tween.written.width * tween.written.height
            let sizeFirst = setSize && (tween.positionOnly || shrinking)
            output.writes.append(FrameWrite(
                window: window, frame: frame, epoch: tween.epoch,
                mode: .intermediate(setSize: setSize, sizeFirst: sizeFirst)
            ))
            tween.written = frame
        }
        tweens[window] = tween
    }
}

private extension CGSize {
    func maxDelta(to other: CGSize) -> Double {
        Double(max(abs(width - other.width), abs(height - other.height)))
    }
}
