import CoreGraphics
import Foundation

/// One frame the animator wants applied to a window. Frames are global top-left-origin points.
public struct FrameWrite: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// The window's resting frame for `epoch`: write `size, position, size`, then read back.
        case final
        /// An animation step. `setSize == false` → write the position only (`frame.size` is
        /// the size the window already has). `sizeFirst` orders the two writes: size before
        /// position when shrinking, position before size when growing.
        case intermediate(setSize: Bool, sizeFirst: Bool)
    }

    public var window: UInt32
    public var frame: CGRect
    /// Epoch of the `AnimationRequest` that produced this write; sinks drop stale epochs.
    public var epoch: UInt64
    public var mode: Mode

    public init(window: UInt32, frame: CGRect, epoch: UInt64, mode: Mode) {
        self.window = window
        self.frame = frame
        self.epoch = epoch
        self.mode = mode
    }

    public var isFinal: Bool { mode == .final }
}

/// Measured cost of writing to a window (normally an EMA kept by the frame writer).
/// Zero latencies mean "not measured yet" and are treated as fast.
public struct WriteCost: Equatable, Sendable {
    public var positionLatencyMs: Double
    public var sizeLatencyMs: Double
    /// A write to this window (or its app) timed out recently (the writer's window, e.g. 5 s).
    public var recentTimeout: Bool

    public init(positionLatencyMs: Double = 0, sizeLatencyMs: Double = 0, recentTimeout: Bool = false) {
        self.positionLatencyMs = positionLatencyMs
        self.sizeLatencyMs = sizeLatencyMs
        self.recentTimeout = recentTimeout
    }

    public static let unmeasured = WriteCost()
}

/// Where animation frames go. Every method is called on the animator thread and must not
/// block: `submit` hands writes off (latest-wins per window), `cost` returns cached stats.
public protocol FrameSink: AnyObject {
    func submit(_ writes: [FrameWrite])
    func cost(window: UInt32) -> WriteCost
    /// The first window of app `pid` started animating (e.g. clear `AXEnhancedUserInterface`).
    /// Called before the writes of that tick are submitted.
    func animationsBegan(pid: pid_t)
    /// The last animating window of app `pid` finished (e.g. restore `AXEnhancedUserInterface`).
    /// Called after the final writes have been submitted.
    func animationsEnded(pid: pid_t)
}

public extension FrameSink {
    func animationsBegan(pid: pid_t) {}
    func animationsEnded(pid: pid_t) {}
}
