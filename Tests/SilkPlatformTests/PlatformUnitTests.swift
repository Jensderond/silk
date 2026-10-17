import CoreGraphics
import Foundation
import Testing
@testable import SilkPlatform

struct EchoRingTests {
    @Test func matchesRecentWritesWithinOnePoint() {
        var ring = EchoRing()
        ring.record(CGRect(x: 100, y: 50, width: 800, height: 600), at: 10)
        #expect(ring.isEcho(CGRect(x: 100.5, y: 49, width: 1, height: 1), kind: .moved, at: 10.1))
        #expect(!ring.isEcho(CGRect(x: 102, y: 50, width: 1, height: 1), kind: .moved, at: 10.1))
        #expect(ring.isEcho(CGRect(x: 0, y: 0, width: 801, height: 599), kind: .resized, at: 10.1))
        #expect(!ring.isEcho(CGRect(x: 100, y: 50, width: 790, height: 600), kind: .resized, at: 10.1))
    }

    @Test func positionAndSizeMatchIndependently() {
        var ring = EchoRing()
        // size-then-position: the intermediate state (new size, old position) must count as ours.
        ring.record(CGRect(x: 0, y: 0, width: 500, height: 500), at: 1)
        #expect(ring.isEcho(CGRect(x: 300, y: 300, width: 500, height: 500), kind: .resized, at: 1.01))
        #expect(!ring.isEcho(CGRect(x: 300, y: 300, width: 500, height: 500), kind: .moved, at: 1.01))
    }

    @Test func entriesExpireAfter500Milliseconds() {
        var ring = EchoRing()
        ring.record(CGRect(x: 1, y: 1, width: 1, height: 1), at: 5)
        #expect(ring.isEcho(CGRect(x: 1, y: 1, width: 1, height: 1), kind: .moved, at: 5.5))
        #expect(!ring.isEcho(CGRect(x: 1, y: 1, width: 1, height: 1), kind: .moved, at: 5.51))
    }

    @Test func keepsOnlyTheLastEightWrites() {
        var ring = EchoRing()
        for i in 0 ..< 9 { ring.record(CGRect(x: CGFloat(i) * 10, y: 0, width: 1, height: 1), at: 1) }
        #expect(!ring.matchesPosition(CGPoint(x: 0, y: 0), at: 1))
        for i in 1 ..< 9 { #expect(ring.matchesPosition(CGPoint(x: CGFloat(i) * 10, y: 0), at: 1)) }
    }
}

struct RegistrationBackoffTests {
    @Test func followsTheScheduleThenRepeatsTheLastStepUntilGivingUp() {
        var backoff = RegistrationBackoff()
        let delays = (0 ..< 40).map { _ in backoff.nextDelay() }
        #expect(Array(delays.prefix(6)) == [0.1, 0.25, 0.5, 1, 2, 2])
        #expect(delays.compactMap { $0 }.count == RegistrationBackoff.maxAttempts - 1)
        #expect(delays.last == .some(nil))
        backoff.reset()
        #expect(backoff.nextDelay() == 0.1)
    }
}

struct WriteLatencyStatsTests {
    @Test func firstSampleSeedsTheAverageAndTimeoutsExpire() {
        var stats = WriteLatencyStats()
        #expect(stats.cost(at: 0) == .unmeasured)
        stats.recordPosition(ms: 4)
        stats.recordPosition(ms: 8)
        #expect(stats.cost(at: 0).positionMs == 5)
        stats.recordTimeout(at: 100)
        #expect(stats.cost(at: 104.9).hadRecentTimeout)
        #expect(!stats.cost(at: 105).hadRecentTimeout)
    }
}

struct GeometryTests {
    @Test func appKitRectsFlipAroundThePrimaryScreen() {
        // Primary 1512x982; a 1920x1080 display above-left of it.
        let primaryHeight: CGFloat = 982
        #expect(ScreenGeometry.topLeftRect(fromAppKit: CGRect(x: 0, y: 0, width: 1512, height: 982), primaryScreenHeight: primaryHeight)
            == CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(ScreenGeometry.topLeftRect(fromAppKit: CGRect(x: 0, y: 0, width: 1512, height: 949), primaryScreenHeight: primaryHeight)
            == CGRect(x: 0, y: 33, width: 1512, height: 949)) // visibleFrame below a 33 pt menu bar
        #expect(ScreenGeometry.topLeftRect(fromAppKit: CGRect(x: -1920, y: 982, width: 1920, height: 1080), primaryScreenHeight: primaryHeight)
            == CGRect(x: -1920, y: -1080, width: 1920, height: 1080))
        #expect(ScreenGeometry.topLeftPoint(fromAppKit: CGPoint(x: 10, y: 982), primaryScreenHeight: primaryHeight) == CGPoint(x: 10, y: 0))
    }

    @Test func monitorsSortLeftToRightThenTopToBottom() {
        func monitor(_ id: String, _ x: CGFloat, _ y: CGFloat) -> MonitorInfo {
            let frame = CGRect(x: x, y: y, width: 100, height: 100)
            return MonitorInfo(id: id, displayID: 0, name: id, frame: frame, visibleFrame: frame, isMain: x == 0 && y == 0, refreshRate: 60)
        }
        let sorted = MonitorInfo.sortedForAeroSpace([monitor("right", 1512, 0), monitor("main", 0, 0), monitor("left-low", -1920, 200), monitor("left-high", -1920, -1080)])
        #expect(sorted.map(\.id) == ["left-high", "left-low", "main", "right"])
    }
}

struct LatencySummaryTests {
    @Test func nearestRankPercentiles() {
        let summary = LatencySummary(samplesMs: (1 ... 20).map(Double.init).shuffled())
        #expect(summary.samples == 20)
        #expect(summary.p50Ms == 10)
        #expect(summary.p95Ms == 19)
        #expect(summary.maxMs == 20)
        #expect(summary.meanMs == 10.5)
        #expect(LatencySummary(samplesMs: []).p95Ms == 0)
    }
}

struct HotkeyModifierTests {
    @Test func mapsToCarbonFlags() {
        #expect(HotkeyModifiers([.cmd, .shift]).carbonFlags == 0x0100 | 0x0200)
        #expect(HotkeyModifiers([.alt, .ctrl]).carbonFlags == 0x0800 | 0x1000)
    }
}
