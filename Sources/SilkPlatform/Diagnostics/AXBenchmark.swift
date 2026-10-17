import AppKit
import ApplicationServices

/// Latency distribution of one kind of AX write, in milliseconds.
public struct LatencySummary: Sendable, Equatable {
    public var samples: Int
    public var p50Ms: Double
    public var p95Ms: Double
    public var meanMs: Double
    public var maxMs: Double

    /// Nearest-rank percentiles.
    public init(samplesMs: [Double]) {
        let sorted = samplesMs.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let rank = Int((p * Double(sorted.count)).rounded(.up))
            return sorted[min(max(rank, 1), sorted.count) - 1]
        }
        samples = sorted.count
        p50Ms = percentile(0.5)
        p95Ms = percentile(0.95)
        meanMs = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
        maxMs = sorted.last ?? 0
    }
}

public struct AXBenchmarkResult: Sendable {
    public var window: UInt32
    public var pid: pid_t
    public var bundleId: String?
    public var position: LatencySummary
    public var size: LatencySummary
    public var originalFrame: CGRect
    /// The read-back after restoring matched the original frame (±1 pt).
    public var restored: Bool
    /// `AXEnhancedUserInterface` was on (and cleared for the measurement).
    public var enhancedUserInterfaceWasOn: Bool
}

public enum AXBenchmarkError: Error, Equatable {
    case notTrusted
    case windowNotFound
    case frameUnreadable
}

/// Measures how long an app takes to service AX position and size writes (`silk debug-bench-ax`).
public enum AXBenchmark {
    /// Writes `iterations` small position deltas (±2 pt) and size deltas (−4 pt width) around the
    /// window's current frame, timing each write, then restores the frame. Blocks the calling
    /// thread for the duration; don't call it on the main thread.
    public static func measure(window: UInt32, pid: pid_t, iterations: Int = 20) throws -> AXBenchmarkResult {
        guard AXIsProcessTrusted() else { throw AXBenchmarkError.notTrusted }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axMessagingTimeout)
        guard let element = app.elements(kAXWindowsAttribute).elements.first(where: { $0.windowID == window }) else {
            throw AXBenchmarkError.windowNotFound
        }
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
        guard let original = element.frame().frame else { throw AXBenchmarkError.frameUnreadable }

        let enhancedUserInterfaceWasOn = app.bool(AXAttribute.enhancedUserInterface) ?? false
        if enhancedUserInterfaceWasOn { app.set(AXAttribute.enhancedUserInterface, kCFBooleanFalse) }
        defer { if enhancedUserInterfaceWasOn { app.set(AXAttribute.enhancedUserInterface, kCFBooleanTrue) } }

        var positionSamples: [Double] = []
        var sizeSamples: [Double] = []
        for iteration in 0 ..< iterations {
            let offset: CGFloat = iteration.isMultiple(of: 2) ? 2 : -2
            positionSamples.append(timed { element.setPosition(CGPoint(x: original.minX + offset, y: original.minY)) })
            let width = iteration.isMultiple(of: 2) ? original.width - 4 : original.width
            sizeSamples.append(timed { element.setSize(CGSize(width: width, height: original.height)) })
        }
        element.setSize(original.size)
        element.setPosition(original.origin)
        element.setSize(original.size)
        let final = element.frame().frame
        let restored = final.map {
            abs($0.minX - original.minX) <= 1 && abs($0.minY - original.minY) <= 1 &&
                abs($0.width - original.width) <= 1 && abs($0.height - original.height) <= 1
        } ?? false

        return AXBenchmarkResult(
            window: window,
            pid: pid,
            bundleId: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
            position: LatencySummary(samplesMs: positionSamples),
            size: LatencySummary(samplesMs: sizeSamples),
            originalFrame: original,
            restored: restored,
            enhancedUserInterfaceWasOn: enhancedUserInterfaceWasOn
        )
    }

    private static func timed(_ body: () -> AXError) -> Double {
        let start = MonotonicClock.now()
        _ = body()
        return (MonotonicClock.now() - start) * 1000
    }
}
