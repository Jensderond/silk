import Foundation

/// Animation behaviour. The Engine maps the user's config into this.
public struct AnimationSettings: Equatable, Sendable {
    /// When false every move becomes a snap.
    public var isEnabled: Bool
    /// Seconds for layout and window-open tweens (bezier/linear curves).
    public var duration: TimeInterval
    /// Seconds for workspace slides (bezier/linear curves).
    public var workspaceDuration: TimeInterval
    public var curve: MotionCurve
    /// Snap everything while macOS "Reduce motion" is on.
    public var respectReduceMotion: Bool
    public var policy: SchedulingPolicy

    public init(
        isEnabled: Bool = true,
        duration: TimeInterval = 0.18,
        workspaceDuration: TimeInterval = 0.22,
        curve: MotionCurve = .hyprland,
        respectReduceMotion: Bool = true,
        policy: SchedulingPolicy = SchedulingPolicy()
    ) {
        self.isEnabled = isEnabled
        self.duration = duration
        self.workspaceDuration = workspaceDuration
        self.curve = curve
        self.respectReduceMotion = respectReduceMotion
        self.policy = policy
    }
}

/// Tuning of the per-app write budget. Defaults follow docs/ARCHITECTURE.md.
public struct SchedulingPolicy: Equatable, Sendable {
    /// k in n = ceil(k · Σ sizeLatency / (frameInterval − Σ positionLatency)): safety margin
    /// so an app's AX thread is never asked for more work per tick than it can do.
    public var sizeCadenceFactor: Double
    /// Size writes at most every n-th tick; beyond that a tween turns position-only.
    public var maxSizeCadence: Int
    /// Size (or position) latency above which a window snaps instead of animating.
    public var snapLatencyMs: Double
    /// Pop-in is downgraded to a plain move above this size latency.
    public var popInMaxSizeLatencyMs: Double
    /// Pop-in start scale relative to the target frame.
    public var popInScale: Double
    /// Moves whose largest component change is below this many points snap.
    public var minimumDelta: Double
    /// Floor for an unmeasured or implausibly small position cost.
    public var minimumPositionCostMs: Double

    public init(
        sizeCadenceFactor: Double = 1.5,
        maxSizeCadence: Int = 3,
        snapLatencyMs: Double = 40,
        popInMaxSizeLatencyMs: Double = 8,
        popInScale: Double = 0.85,
        minimumDelta: Double = 2,
        minimumPositionCostMs: Double = 0.5
    ) {
        self.sizeCadenceFactor = sizeCadenceFactor
        self.maxSizeCadence = maxSizeCadence
        self.snapLatencyMs = snapLatencyMs
        self.popInMaxSizeLatencyMs = popInMaxSizeLatencyMs
        self.popInScale = popInScale
        self.minimumDelta = minimumDelta
        self.minimumPositionCostMs = minimumPositionCostMs
    }
}
