import CoreGraphics
import Foundation
import Testing
@testable import SilkPlatform

/// Records drains instead of running them, so tests control when the "worker" gets to run.
private final class FakeTarget: FrameWriteTarget {
    let pid: pid_t
    var scheduledDrains: [() -> Void] = []
    var performed: [[FrameWrite]] = []

    init(pid: pid_t) { self.pid = pid }

    func scheduleDrain(_ drain: @escaping () -> Void) { scheduledDrains.append(drain) }
    func performFrameWrites(_ writes: [FrameWrite]) { performed.append(writes) }
    func performBlockingRestore(_ frames: [(UInt32, CGRect)], completion: @escaping (Set<UInt32>) -> Void) {
        completion(Set(frames.map(\.0)))
    }

    func runDrains() {
        let drains = scheduledDrains
        scheduledDrains = []
        drains.forEach { $0() }
    }
}

struct FrameWriterTests {
    private let appA = FakeTarget(pid: 1)
    private let appB = FakeTarget(pid: 2)
    private let writer: FrameWriter

    init() {
        let (a, b) = (appA, appB)
        writer = FrameWriter(resolveTarget: { window in
            switch window {
                case 10, 11: a
                case 20: b
                default: nil
            }
        })
    }

    private func write(_ window: UInt32, x: CGFloat, epoch: UInt64, mode: FrameWrite.Mode = .intermediate(setSize: false, sizeFirst: false)) -> FrameWrite {
        FrameWrite(window: window, frame: CGRect(x: x, y: 0, width: 100, height: 100), epoch: epoch, mode: mode)
    }

    @Test func latestWriteWinsWhileWorkerIsBusy() {
        writer.submit([write(10, x: 1, epoch: 1)])
        writer.submit([write(10, x: 2, epoch: 1)])
        writer.submit([write(10, x: 3, epoch: 1, mode: .final)])
        #expect(appA.scheduledDrains.count == 1)
        appA.runDrains()
        #expect(appA.performed == [[write(10, x: 3, epoch: 1, mode: .final)]])
    }

    @Test func oneDrainPerAppCoversAllItsWindowsInSubmissionOrder() {
        writer.submit([write(11, x: 1, epoch: 1), write(10, x: 1, epoch: 1), write(20, x: 1, epoch: 1)])
        writer.submit([write(11, x: 2, epoch: 1)])
        #expect(appA.scheduledDrains.count == 1)
        #expect(appB.scheduledDrains.count == 1)
        appA.runDrains()
        #expect(appA.performed == [[write(11, x: 2, epoch: 1), write(10, x: 1, epoch: 1)]])
    }

    @Test func submittingAfterDrainSchedulesAnotherDrain() {
        writer.submit([write(10, x: 1, epoch: 1)])
        appA.runDrains()
        writer.submit([write(10, x: 2, epoch: 1)])
        #expect(appA.scheduledDrains.count == 1)
        appA.runDrains()
        #expect(appA.performed.map { $0.map(\.frame.minX) } == [[1], [2]])
    }

    @Test func staleEpochsAreDropped() {
        writer.submit([write(10, x: 1, epoch: 5)])
        writer.submit([write(10, x: 2, epoch: 4)])
        appA.runDrains()
        writer.submit([write(10, x: 3, epoch: 3)])
        #expect(appA.scheduledDrains.isEmpty)
        writer.submit([write(10, x: 4, epoch: 5), write(10, x: 5, epoch: 6)])
        appA.runDrains()
        #expect(appA.performed.map { $0.map(\.frame.minX) } == [[1], [5]])
    }

    @Test func epochsArePerWindow() {
        writer.submit([write(10, x: 1, epoch: 9)])
        writer.submit([write(11, x: 1, epoch: 2)])
        appA.runDrains()
        #expect(appA.performed.first?.count == 2)
    }

    @Test func unknownWindowsAreIgnored() {
        writer.submit([write(99, x: 1, epoch: 1)])
        #expect(appA.scheduledDrains.isEmpty && appB.scheduledDrains.isEmpty)
    }

    @Test func cancelDropsThePendingWrite() {
        writer.submit([write(10, x: 1, epoch: 1), write(11, x: 1, epoch: 1)])
        writer.cancel(window: 10)
        appA.runDrains()
        #expect(appA.performed == [[write(11, x: 1, epoch: 1)]])
        // A drain that finds nothing performs nothing.
        writer.submit([write(10, x: 2, epoch: 1)])
        writer.cancel(window: 10)
        appA.runDrains()
        #expect(appA.performed.count == 1)
    }

    @Test func forgettingAWindowResetsItsEpoch() {
        writer.submit([write(10, x: 1, epoch: 7)])
        appA.runDrains()
        writer.forget(window: 10, target: appA)
        writer.submit([write(10, x: 2, epoch: 1)])
        appA.runDrains()
        #expect(appA.performed.count == 2)
    }

    @Test func costReflectsMeasuredLatencyPerApp() {
        #expect(writer.cost(window: 10) == .unmeasured)
        writer.recordLatency(pid: 1, attribute: .position, milliseconds: 2, timedOut: false)
        writer.recordLatency(pid: 1, attribute: .size, milliseconds: 20, timedOut: false)
        writer.recordLatency(pid: 1, attribute: .size, milliseconds: 40, timedOut: false)
        let cost = writer.cost(window: 11)
        #expect(cost.positionMs == 2)
        #expect(cost.sizeMs == 25) // 20 + 0.25 * (40 - 20)
        #expect(cost.samples == 3)
        #expect(!cost.hadRecentTimeout)
        #expect(writer.cost(window: 20) == .unmeasured)
        writer.recordLatency(pid: 1, attribute: .size, milliseconds: 1000, timedOut: true)
        #expect(writer.cost(window: 10).hadRecentTimeout)
        #expect(writer.cost(window: 10).sizeMs == 25)
    }

    @Test func writeSynchronouslyCancelsPendingWritesAndReportsWrittenWindows() {
        writer.submit([write(10, x: 1, epoch: 1)])
        let written = writer.writeSynchronously(
            [(10, CGRect(x: 0, y: 0, width: 10, height: 10)), (20, .zero), (99, .zero)],
            deadline: .now() + 1
        )
        #expect(written == [10, 20])
        appA.runDrains()
        #expect(appA.performed.isEmpty)
    }
}
