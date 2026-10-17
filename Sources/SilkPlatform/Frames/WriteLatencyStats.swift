import Foundation

/// Monotonic seconds (`CLOCK_UPTIME_RAW`), comparable across threads and processes.
enum MonotonicClock {
    static func now() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }
}

/// Exponential moving averages of one app's AX write latencies. Not thread-safe; ``FrameWriter``
/// guards it.
struct WriteLatencyStats {
    static let smoothing = 0.25
    static let timeoutMemory: TimeInterval = 5

    private(set) var positionMs: Double?
    private(set) var sizeMs: Double?
    private(set) var samples = 0
    private var lastTimeout: TimeInterval?

    mutating func recordPosition(ms: Double) {
        positionMs = Self.blend(positionMs, ms)
        samples += 1
    }

    mutating func recordSize(ms: Double) {
        sizeMs = Self.blend(sizeMs, ms)
        samples += 1
    }

    mutating func recordTimeout(at time: TimeInterval) {
        lastTimeout = time
    }

    func cost(at time: TimeInterval) -> WriteCost {
        WriteCost(
            positionMs: positionMs ?? WriteCost.unmeasured.positionMs,
            sizeMs: sizeMs ?? WriteCost.unmeasured.sizeMs,
            hadRecentTimeout: lastTimeout.map { time - $0 < Self.timeoutMemory } ?? false,
            samples: samples
        )
    }

    private static func blend(_ average: Double?, _ sample: Double) -> Double {
        guard let average else { return sample }
        return average + smoothing * (sample - average)
    }
}
