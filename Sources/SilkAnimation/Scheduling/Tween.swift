import CoreGraphics
import Foundation

/// One window's in-flight animation. Frames are kept as SIMD4 (x, y, width, height).
struct Tween {
    let window: UInt32
    let pid: pid_t
    var displayID: CGDirectDisplayID
    let epoch: UInt64
    /// Workspace slides: the size jumps to `to`'s size on the first write, then only the
    /// position moves.
    let positionOnly: Bool
    /// The tween changes the window's size along the curve (never true when `positionOnly`).
    let animatesSize: Bool
    let from: SIMD4<Double>
    let to: SIMD4<Double>
    /// What the final write sets: `to`, or the move's follow-up frame.
    let restingFrame: CGRect
    let start: Double
    let end: Double
    let curve: MotionCurve
    /// Initial velocity in points per second; only springs use it.
    let initialVelocity: SIMD4<Double>
    /// The frame the window was last written to (or its frame before the first write).
    var written: CGRect
    var ticks = 0

    /// Interpolated (unclamped, unrounded) frame and its velocity in points per second.
    func sample(at now: Double) -> (value: SIMD4<Double>, velocity: SIMD4<Double>) {
        let t = max(now - start, 0)
        let duration = end - start
        let progress: Double, rate: Double
        switch curve {
        case .spring(let spring):
            let state = spring.state(at: t, displacement: from - to, velocity: initialVelocity)
            return (to + state.displacement, state.velocity)
        case .linear:
            progress = duration > 0 ? min(t / duration, 1) : 1
            rate = progress < 1 && duration > 0 ? 1 / duration : 0
        case .bezier(let bezier):
            let x = duration > 0 ? min(t / duration, 1) : 1
            progress = bezier.value(at: x)
            rate = x < 1 && duration > 0 ? bezier.slope(at: x) / duration : 0
        }
        return (from + (to - from) * progress, (to - from) * rate)
    }

    /// Velocity to hand to a retargeted tween: position velocity as sampled; size velocity
    /// only while the size is actually following the curve (not clamped, not position-only).
    func retargetVelocity(at now: Double) -> SIMD4<Double> {
        let (value, velocity) = sample(at: now)
        let size = SIMD2(value[2], value[3])
        let sizeFollowsCurve = animatesSize
            && all(size .>= sizeLowerBound) && all(size .<= sizeUpperBound)
        return sizeFollowsCurve ? velocity : SIMD4(velocity[0], velocity[1], 0, 0)
    }

    var sizeLowerBound: SIMD2<Double> { pointwiseMin(SIMD2(from[2], from[3]), SIMD2(to[2], to[3])) }
    var sizeUpperBound: SIMD2<Double> { pointwiseMax(SIMD2(from[2], from[3]), SIMD2(to[2], to[3])) }
    var targetSize: SIMD2<Double> { SIMD2(to[2], to[3]) }
}

extension SIMD4 where Scalar == Double {
    init(_ rect: CGRect) {
        self.init(Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height))
    }
}

extension CGRect {
    /// Largest absolute change of origin or size component between two frames.
    func maxComponentDelta(to other: CGRect) -> Double {
        let difference = SIMD4<Double>(self) - SIMD4<Double>(other)
        return pointwiseMax(difference, -difference).max()
    }

    func scaledAroundCenter(by scale: Double) -> CGRect {
        let width = Double(self.width) * scale, height = Double(self.height) * scale
        return CGRect(x: Double(midX) - width / 2, y: Double(midY) - height / 2, width: width, height: height)
    }
}
