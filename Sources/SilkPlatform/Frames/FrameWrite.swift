import CoreGraphics

/// One frame write request for a window (global top-left coordinates).
public struct FrameWrite: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// `size, position, size`, then one read-back reported as ``PlatformEvent/frameApplied(_:_:)``.
        case final
        /// One animation tick. `setSize == false` writes position only; otherwise `sizeFirst`
        /// orders the two writes (size first when shrinking, position first when growing).
        case intermediate(setSize: Bool, sizeFirst: Bool)
    }

    public var window: UInt32
    public var frame: CGRect
    /// Layout epoch; writes older than the newest epoch seen for the window are dropped.
    public var epoch: UInt64
    public var mode: Mode

    public init(window: UInt32, frame: CGRect, epoch: UInt64, mode: Mode) {
        self.window = window
        self.frame = frame
        self.epoch = epoch
        self.mode = mode
    }
}

/// Measured cost of writing to a window's app (exponential moving averages).
public struct WriteCost: Sendable, Equatable {
    /// Average `kAXPosition` write latency in milliseconds.
    public var positionMs: Double
    /// Average `kAXSize` write latency in milliseconds.
    public var sizeMs: Double
    /// An AX write to the app timed out within the last 5 seconds.
    public var hadRecentTimeout: Bool
    /// Number of writes measured so far (0 = the values are priors).
    public var samples: Int

    public init(positionMs: Double, sizeMs: Double, hadRecentTimeout: Bool, samples: Int) {
        self.positionMs = positionMs
        self.sizeMs = sizeMs
        self.hadRecentTimeout = hadRecentTimeout
        self.samples = samples
    }

    /// Prior used before anything was measured: typical AppKit app.
    public static let unmeasured = WriteCost(positionMs: 1, sizeMs: 5, hadRecentTimeout: false, samples: 0)
}
