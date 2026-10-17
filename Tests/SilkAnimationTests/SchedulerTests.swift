import CoreGraphics
import Foundation
import Testing
@testable import SilkAnimation

@Suite struct SchedulerBudgetTests {
    private let small = CGRect(x: 0, y: 0, width: 100, height: 100)
    private let large = CGRect(x: 300, y: 200, width: 400, height: 400)

    private func intermediateWrites(_ outputs: [SchedulerOutput]) -> [FrameWrite] {
        outputs.flatMap(\.writes).filter { !$0.isFinal }
    }

    @Test func fastAppWritesSizeEveryTick() {
        var run = Run(settings())
        run.costs[1] = WriteCost(positionLatencyMs: 0.5, sizeLatencyMs: 2)
        #expect(run.apply([move(from: small, to: large)]).writes.isEmpty)
        let outputs = run.runToEnd()
        let steps = intermediateWrites(outputs)
        #expect(steps.count >= 10)
        #expect(steps.allSatisfy { $0.mode.setsSize })
        #expect(outputs.last?.writes == [FrameWrite(window: 1, frame: large, epoch: 1, mode: .final)])
    }

    @Test func moderatelySlowAppWritesSizeEveryThirdTick() {
        var run = Run(settings())
        // n = ceil(1.5 · 30 / (16.67 − 0.5)) = 3
        run.costs[1] = WriteCost(positionLatencyMs: 0.5, sizeLatencyMs: 30)
        _ = run.apply([move(from: small, to: large)])
        let steps = intermediateWrites(run.runToEnd())
        #expect(steps.count >= 10)
        for (index, write) in steps.enumerated() {
            #expect(write.mode.setsSize == (index % 3 == 0), "tick \(index)")
        }
    }

    @Test func appsShareOneBudget() {
        // Alone: n = ceil(1.5 · 12 / 16.17) = 2. Two windows of the same app: ΣS = 24, ΣP = 1
        // → n = ceil(1.5 · 24 / 15.67) = 3.
        var alone = Run(settings())
        alone.costs[1] = WriteCost(positionLatencyMs: 0.5, sizeLatencyMs: 12)
        _ = alone.apply([move(1, from: small, to: large)])
        let aloneSteps = intermediateWrites(alone.runToEnd())
        #expect(aloneSteps.prefix(6).map(\.mode.setsSize) == [true, false, true, false, true, false])

        var shared = Run(settings())
        shared.costs[1] = WriteCost(positionLatencyMs: 0.5, sizeLatencyMs: 12)
        shared.costs[2] = WriteCost(positionLatencyMs: 0.5, sizeLatencyMs: 12)
        _ = shared.apply([move(1, from: small, to: large), move(2, from: small.offsetBy(dx: 0, dy: 500), to: large.offsetBy(dx: 0, dy: 500))])
        let sharedSteps = intermediateWrites(shared.runToEnd()).filter { $0.window == 1 }
        #expect(sharedSteps.prefix(6).map(\.mode.setsSize) == [true, false, false, true, false, false])
    }

    @Test func slowAppShrinkingSetsFinalSizeFirstThenSlides() {
        var run = Run(settings())
        // n = ceil(1.5 · 35 / 16.17) = 4 > 3 → position-only.
        run.costs[1] = WriteCost(positionLatencyMs: 0.5, sizeLatencyMs: 35)
        let from = CGRect(x: 0, y: 0, width: 800, height: 600)
        let to = CGRect(x: 400, y: 0, width: 400, height: 600)
        _ = run.apply([move(from: from, to: to)])
        let outputs = run.runToEnd()
        let steps = intermediateWrites(outputs)
        let first = try! #require(steps.first)
        #expect(first.mode == .intermediate(setSize: true, sizeFirst: true))
        #expect(first.frame.size == to.size)
        #expect(steps.dropFirst().allSatisfy { !$0.mode.setsSize && $0.frame.size == to.size })
        #expect(Set(steps.map(\.frame.minX)).count > 5)
        #expect(outputs.last?.writes.last == FrameWrite(window: 1, frame: to, epoch: 1, mode: .final))
    }

    @Test func slowAppGrowingSetsSizeOnlyWithTheFinalWrite() {
        var run = Run(settings())
        run.costs[1] = WriteCost(positionLatencyMs: 0.5, sizeLatencyMs: 35)
        let from = CGRect(x: 400, y: 0, width: 400, height: 600)
        let to = CGRect(x: 0, y: 0, width: 800, height: 600)
        _ = run.apply([move(from: from, to: to)])
        let outputs = run.runToEnd()
        let steps = intermediateWrites(outputs)
        #expect(steps.count > 5)
        #expect(steps.allSatisfy { !$0.mode.setsSize && $0.frame.size == from.size })
        #expect(outputs.last?.writes.last == FrameWrite(window: 1, frame: to, epoch: 1, mode: .final))
    }

    @Test func slowMixedResizeShrinksNowGrowsAtTheEnd() {
        var run = Run(settings())
        run.costs[1] = WriteCost(positionLatencyMs: 0.5, sizeLatencyMs: 35)
        let from = CGRect(x: 0, y: 0, width: 800, height: 300)
        let to = CGRect(x: 100, y: 100, width: 400, height: 600)
        _ = run.apply([move(from: from, to: to)])
        let steps = intermediateWrites(run.runToEnd())
        #expect(steps.first?.frame.size == CGSize(width: 400, height: 300))
    }

    @Test func verySlowAppSnaps() {
        var run = Run(settings())
        run.costs[1] = WriteCost(positionLatencyMs: 1, sizeLatencyMs: 45)
        let output = run.apply([move(from: small, to: large)])
        #expect(output.writes == [FrameWrite(window: 1, frame: large, epoch: 1, mode: .final)])
        #expect(output.completions == [AnimationCompletion(window: 1, epoch: 1)])
        #expect(output.appsBegan.isEmpty && output.appsEnded.isEmpty)
        #expect(run.scheduler.isIdle)
    }

    @Test func recentTimeoutSnaps() {
        var run = Run(settings())
        run.costs[1] = WriteCost(positionLatencyMs: 1, sizeLatencyMs: 1, recentTimeout: true)
        #expect(run.apply([move(from: small, to: large)]).writes.map(\.mode) == [.final])
        #expect(run.scheduler.isIdle)
    }

    @Test func degradingCostSnapsMidFlight() {
        var run = Run(settings())
        _ = run.apply([move(from: small, to: large)])
        _ = run.tick()
        run.costs[1] = WriteCost(positionLatencyMs: 1, sizeLatencyMs: 50)
        let output = run.tick()
        #expect(output.writes == [FrameWrite(window: 1, frame: large, epoch: 1, mode: .final)])
        #expect(output.appsEnded == [100])
    }

    @Test func slowSizeDoesNotStopPositionOnlySlides() {
        var run = Run(settings())
        run.costs[1] = WriteCost(positionLatencyMs: 1, sizeLatencyMs: 80)
        _ = run.apply([move(from: small, to: small.offsetBy(dx: 600, dy: 0), kind: .workspaceIn)])
        #expect(!run.scheduler.isIdle)
    }
}

@Suite struct SchedulerMotionTests {
    @Test func overshootMovesPositionButClampsSize() {
        var run = Run(settings(curve: .hyprland, duration: 0.3))
        let from = CGRect(x: 0, y: 0, width: 100, height: 100)
        let to = CGRect(x: 1000, y: 0, width: 200, height: 200)
        _ = run.apply([move(from: from, to: to)])
        let writes = run.runToEnd().flatMap(\.writes)
        let steps = writes.filter { !$0.isFinal }
        #expect(steps.contains { $0.frame.minX > to.minX })
        #expect(steps.allSatisfy { $0.frame.width >= 100 && $0.frame.width <= 200 })
        #expect(steps.allSatisfy { $0.frame.height >= 100 && $0.frame.height <= 200 })
        #expect(writes.last?.frame == to)
    }

    @Test func intermediateWriteOrderFollowsResizeDirection() {
        var grow = Run(settings())
        _ = grow.apply([move(from: CGRect(x: 0, y: 0, width: 100, height: 100), to: CGRect(x: 50, y: 0, width: 400, height: 400))])
        let growSteps = grow.runToEnd().flatMap(\.writes).filter { !$0.isFinal && $0.mode.setsSize }
        #expect(!growSteps.isEmpty && growSteps.allSatisfy { !$0.mode.sizeFirst })

        var shrink = Run(settings())
        _ = shrink.apply([move(from: CGRect(x: 0, y: 0, width: 400, height: 400), to: CGRect(x: 50, y: 0, width: 100, height: 100))])
        let shrinkSteps = shrink.runToEnd().flatMap(\.writes).filter { !$0.isFinal && $0.mode.setsSize }
        #expect(!shrinkSteps.isEmpty && shrinkSteps.allSatisfy { $0.mode.sizeFirst })
    }

    @Test func epochsPropagateAndRetargetsReplaceThem() {
        var run = Run(settings())
        let from = CGRect(x: 0, y: 0, width: 300, height: 300)
        _ = run.apply([move(from: from, to: from.offsetBy(dx: 600, dy: 0))], epoch: 7)
        let early = (0..<3).flatMap { _ in run.tick().writes }
        #expect(!early.isEmpty && early.allSatisfy { $0.epoch == 7 })

        _ = run.apply([move(from: .zero, to: from.offsetBy(dx: 0, dy: 400))], epoch: 8)
        let outputs = run.runToEnd()
        let late = outputs.flatMap(\.writes)
        #expect(!late.isEmpty && late.allSatisfy { $0.epoch == 8 })
        #expect(outputs.flatMap(\.completions) == [AnimationCompletion(window: 1, epoch: 8)])
    }

    @Test func retargetStartsFromPresentedFrame() throws {
        var run = Run(settings())
        let from = CGRect(x: 0, y: 0, width: 300, height: 300)
        _ = run.apply([move(from: from, to: from.offsetBy(dx: 600, dy: 0))])
        for _ in 0..<4 { _ = run.tick() }
        let presented = try #require(run.scheduler.presentedFrame(window: 1))
        #expect(presented.minX > 0 && presented.minX < 600)
        // `from` is ignored for an animating window.
        _ = run.apply([move(from: CGRect(x: 5000, y: 5000, width: 1, height: 1), to: from)], epoch: 2)
        let tween = try #require(run.scheduler.tweens[1])
        #expect(tween.from == SIMD4(presented))
    }

    @Test func springRetargetPreservesVelocity() throws {
        var run = Run(settings(curve: .defaultSpring))
        let from = CGRect(x: 0, y: 0, width: 300, height: 300)
        _ = run.apply([move(from: from, to: from.offsetBy(dx: 1000, dy: 0))])
        for _ in 0..<6 { _ = run.tick() }
        let before = try #require(run.scheduler.tweens[1]).sample(at: run.now).velocity
        #expect(before[0] > 500)

        _ = run.apply([move(from: from, to: from.offsetBy(dx: -500, dy: 300))], epoch: 2)
        let after = try #require(run.scheduler.tweens[1]).sample(at: run.now).velocity
        #expect(abs(after[0] - before[0]) < 1e-6)
        #expect(abs(after[1] - before[1]) < 1e-6)
        // The velocity carries on: the next frame still moves right before turning around.
        let next = run.tick().writes.first
        #expect((next?.frame.minX ?? 0) > (run.scheduler.tweens[1]?.from[0] ?? .infinity) - 1)
    }

    @Test func springSettlesWithAFinalWrite() {
        var run = Run(settings(curve: .spring(Spring(response: 0.25, dampingRatio: 0.6))))
        let to = CGRect(x: 800, y: 100, width: 500, height: 400)
        _ = run.apply([move(from: CGRect(x: 0, y: 0, width: 300, height: 300), to: to)])
        let outputs = run.runToEnd()
        #expect(run.scheduler.isIdle)
        #expect(outputs.count < 120)
        let steps = outputs.flatMap(\.writes).filter { !$0.isFinal }
        #expect(steps.contains { $0.frame.minX > to.minX })  // bounces
        #expect(steps.allSatisfy { $0.frame.width <= to.width && $0.frame.height <= to.height })
        #expect(outputs.last?.writes.last == FrameWrite(window: 1, frame: to, epoch: 1, mode: .final))
    }

    @Test func tinyMovesSnap() {
        var run = Run(settings())
        let from = CGRect(x: 0, y: 0, width: 100, height: 100)
        let to = CGRect(x: 1.5, y: -1, width: 101.9, height: 100)
        let output = run.apply([move(from: from, to: to)])
        #expect(output.writes == [FrameWrite(window: 1, frame: to, epoch: 1, mode: .final)])
        #expect(run.scheduler.isIdle)
    }

    @Test func deadlineAlwaysEmitsFinal() {
        var run = Run(settings())
        let to = CGRect(x: 900, y: 0, width: 200, height: 200)
        _ = run.apply([move(from: CGRect(x: 0, y: 0, width: 100, height: 100), to: to)])
        _ = run.tick()
        // One very late tick (dropped frames, hitch): the tween ends with its final write.
        let output = run.tick(interval: 0.5)
        #expect(output.writes == [FrameWrite(window: 1, frame: to, epoch: 1, mode: .final)])
        #expect(run.scheduler.isIdle)
    }

    @Test func overdueTweensFinishWithoutTicks() {
        var run = Run(settings())
        _ = run.apply([move(from: .init(x: 0, y: 0, width: 100, height: 100), to: .init(x: 500, y: 0, width: 100, height: 100))])
        #expect(run.scheduler.nextDeadline == 0.2)
        #expect(run.scheduler.finishOverdue(now: 0.25, grace: 0.1).writes.isEmpty)
        #expect(run.scheduler.finishOverdue(now: 0.31, grace: 0.1).writes.map(\.mode) == [.final])
    }

    @Test func workspaceSlidesArePositionOnlyWithSizeAppliedFirst() {
        var run = Run(settings())
        let from = CGRect(x: -800, y: 0, width: 500, height: 500)
        let to = CGRect(x: 0, y: 0, width: 600, height: 600)
        _ = run.apply([move(from: from, to: to, kind: .workspaceIn)])
        let outputs = run.runToEnd()
        let steps = outputs.flatMap(\.writes).filter { !$0.isFinal }
        #expect(steps.first?.mode == .intermediate(setSize: true, sizeFirst: true))
        #expect(steps.allSatisfy { $0.frame.size == to.size })
        #expect(steps.dropFirst().allSatisfy { !$0.mode.setsSize })
        #expect(outputs.last?.writes.last?.frame == to)
    }

    @Test func workspaceOutEndsAtFollowUpFrame() {
        var run = Run(settings())
        let from = CGRect(x: 0, y: 0, width: 600, height: 600)
        let exit = CGRect(x: -599, y: 0, width: 600, height: 600)
        let corner = CGRect(x: -599, y: 1439, width: 600, height: 600)
        _ = run.apply([move(from: from, to: exit, kind: .workspaceOut, then: corner)], epoch: 3)
        let outputs = run.runToEnd()
        #expect(outputs.flatMap(\.writes).filter { !$0.isFinal }.allSatisfy { $0.frame.minY == 0 })
        #expect(outputs.last?.writes == [FrameWrite(window: 1, frame: corner, epoch: 3, mode: .final)])
        #expect(outputs.last?.completions == [AnimationCompletion(window: 1, epoch: 3)])
    }

    @Test func retargetDropsFollowUpFrame() {
        var run = Run(settings())
        let from = CGRect(x: 0, y: 0, width: 600, height: 600)
        _ = run.apply([move(from: from, to: from.offsetBy(dx: -599, dy: 0), kind: .workspaceOut, then: .init(x: -599, y: 1439, width: 600, height: 600))])
        _ = run.tick()
        _ = run.apply([move(from: from, to: from, kind: .workspaceIn)], epoch: 2)
        let outputs = run.runToEnd()
        #expect(outputs.last?.writes.last == FrameWrite(window: 1, frame: from, epoch: 2, mode: .final))
    }

    @Test func popInStartsScaledDownAndDowngradesForSlowApps() throws {
        let initial = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let tile = CGRect(x: 100, y: 100, width: 500, height: 400)

        var fast = Run(settings())
        fast.costs[1] = WriteCost(positionLatencyMs: 0.5, sizeLatencyMs: 3)
        _ = fast.apply([move(from: initial, to: tile, kind: .open(.popIn))])
        let tween = try #require(fast.scheduler.tweens[1])
        #expect(tween.from == SIMD4(CGRect(x: 137.5, y: 130, width: 425, height: 340)))
        let first = try #require(fast.tick().writes.first)
        #expect(first.mode == .intermediate(setSize: true, sizeFirst: true))
        #expect(first.frame.width < 450)

        var slow = Run(settings())
        slow.costs[1] = WriteCost(positionLatencyMs: 0.5, sizeLatencyMs: 9)
        _ = slow.apply([move(from: initial, to: tile, kind: .open(.popIn))])
        #expect(try #require(slow.scheduler.tweens[1]).from == SIMD4(initial))
    }

    @Test func requestSnapsCancelTweens() {
        var run = Run(settings())
        _ = run.apply([move(from: .init(x: 0, y: 0, width: 100, height: 100), to: .init(x: 500, y: 0, width: 100, height: 100))])
        _ = run.tick()
        let target = CGRect(x: 10, y: 10, width: 50, height: 50)
        let output = run.apply([], epoch: 2, snaps: [.init(window: 1, frame: target)])
        #expect(output.writes == [FrameWrite(window: 1, frame: target, epoch: 2, mode: .final)])
        #expect(output.appsEnded == [100])
        #expect(run.scheduler.isIdle)
    }

    @Test func appLifecycleAndCancel() {
        var run = Run(settings())
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let began = run.apply([move(1, from: a, to: a.offsetBy(dx: 400, dy: 0)), move(2, from: a, to: a.offsetBy(dx: 0, dy: 400))])
        #expect(began.appsBegan == [100])
        let cancelled = run.scheduler.cancel(window: 1)
        #expect(cancelled.writes.isEmpty && cancelled.appsEnded.isEmpty)
        let outputs = run.runToEnd()
        #expect(outputs.flatMap(\.writes).allSatisfy { $0.window == 2 })
        #expect(outputs.last?.appsEnded == [100])
    }

    @Test func ticksOnlyAdvanceTheirDisplay() {
        var run = Run(settings())
        var other = move(from: .init(x: 0, y: 0, width: 100, height: 100), to: .init(x: 500, y: 0, width: 100, height: 100))
        other.displayID = 2
        _ = run.apply([other])
        #expect(run.tick().writes.isEmpty)
        #expect(run.scheduler.activeDisplays == [2])
        run.scheduler.reassignDisplays(available: [display], fallback: display)
        #expect(!run.tick().writes.isEmpty)
    }
}

@Suite struct ReduceMotionTests {
    private let from = CGRect(x: 0, y: 0, width: 100, height: 100)
    private let to = CGRect(x: 600, y: 0, width: 300, height: 300)

    @Test func reduceMotionSnapsWhenRespected() {
        var run = Run(settings())
        run.scheduler.reduceMotion = true
        #expect(run.scheduler.isSnapping)
        #expect(run.apply([move(from: from, to: to)]).writes == [FrameWrite(window: 1, frame: to, epoch: 1, mode: .final)])
        #expect(run.scheduler.isIdle)
    }

    @Test func reduceMotionIgnoredWhenNotRespected() {
        var custom = settings()
        custom.respectReduceMotion = false
        var run = Run(custom)
        run.scheduler.reduceMotion = true
        _ = run.apply([move(from: from, to: to)])
        #expect(!run.scheduler.isIdle)
    }

    @Test func disabledAnimationsSnap() {
        var custom = settings()
        custom.isEnabled = false
        var run = Run(custom)
        #expect(run.apply([move(from: from, to: to)]).writes.map(\.mode) == [.final])
    }

    @Test func snapAllFinishesEverything() {
        var run = Run(settings())
        _ = run.apply([move(1, from: from, to: to), move(2, pid: 200, from: from, to: to.offsetBy(dx: 0, dy: 400))])
        let output = run.scheduler.snapAll()
        #expect(output.writes.map(\.window) == [1, 2] && output.writes.allSatisfy(\.isFinal))
        #expect(output.appsEnded == [100, 200])
    }
}
