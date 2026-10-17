import Foundation

/// How a tween moves from its start to its target.
public enum MotionCurve: Equatable, Sendable {
    /// Fixed-duration cubic bezier timing curve; may overshoot.
    case bezier(UnitBezier)
    /// Physically based; duration follows from the spring and the distance, velocity is
    /// carried across retargets.
    case spring(Spring)
    case linear

    /// Hyprland's default `bezier = myBezier, 0.05, 0.9, 0.1, 1.05` (overshoots ~5 %).
    public static let hyprland = MotionCurve.bezier(UnitBezier(x1: 0.05, y1: 0.9, x2: 0.1, y2: 1.05))
    public static let easeOut = MotionCurve.bezier(UnitBezier(x1: 0.16, y1: 1, x2: 0.3, y2: 1))
    /// Critically damped, settles in roughly `response` seconds for typical distances.
    public static let defaultSpring = MotionCurve.spring(Spring(response: 0.3, dampingRatio: 1))
}
