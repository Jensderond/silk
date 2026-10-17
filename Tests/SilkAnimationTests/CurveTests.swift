import Foundation
import Testing
@testable import SilkAnimation

@Suite struct BezierTests {
    /// Reference values from a 200-step bisection on the parametric curve.
    @Test(arguments: [
        (0.1, 0.09479630571604324), (0.25, 0.40851059135539586), (0.5, 0.802403387584857),
        (0.75, 0.9604589783489741), (0.9, 0.9943164774845563),
    ])
    func cssEaseMatchesReference(x: Double, expected: Double) {
        let ease = UnitBezier(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
        #expect(abs(ease.value(at: x) - expected) < 1e-6)
    }

    @Test(arguments: [
        (0.1, 0.7224511947866501), (0.25, 0.9145725168253769), (0.5, 0.9956064952500733),
        (0.75, 1.0084750064927164), (0.9, 1.0048454160655462),
    ])
    func hyprlandMatchesReferenceIncludingOvershoot(x: Double, expected: Double) {
        guard case .bezier(let hyprland) = MotionCurve.hyprland else { Issue.record("not a bezier"); return }
        #expect(abs(hyprland.value(at: x) - expected) < 1e-6)
    }

    @Test func endpointsAndClamping() {
        let curve = UnitBezier(x1: 0.05, y1: 0.9, x2: 0.1, y2: 1.05)
        #expect(curve.value(at: 0) == 0)
        #expect(abs(curve.value(at: 1) - 1) < 1e-9)
        #expect(curve.value(at: -1) == 0)
        #expect(abs(curve.value(at: 2) - 1) < 1e-9)
        // Control x outside [0, 1] is clamped so x(t) stays monotonic.
        #expect(UnitBezier(x1: -1, y1: 0, x2: 2, y2: 1).x1 == 0)
    }

    @Test func linearControlPointsAreIdentity() {
        let linear = UnitBezier(x1: 0, y1: 0, x2: 1, y2: 1)
        for x in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(abs(linear.value(at: x) - x) < 1e-6)
        }
    }

    @Test func slopeMatchesFiniteDifference() {
        let curve = UnitBezier(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
        for x in [0.2, 0.4, 0.5, 0.7] {
            let h = 1e-5
            let numeric = (curve.value(at: x + h) - curve.value(at: x - h)) / (2 * h)
            #expect(abs(curve.slope(at: x) - numeric) < 1e-3)
        }
    }

    /// With x1 = x2 = 0, x(t) = t³ has a zero derivative at t = 0, where Newton stalls and the
    /// bisection fallback must take over; y(x) = 1 − (1 − ∛x)³ in closed form.
    @Test(arguments: [1e-6, 0.001, 0.1, 0.5, 0.95])
    func bisectionFallbackHandlesFlatDerivative(x: Double) {
        let curve = UnitBezier(x1: 0, y1: 1, x2: 0, y2: 1)
        let exact = 1 - pow(1 - cbrt(x), 3)
        #expect(abs(curve.value(at: x) - exact) < 1e-5)
    }
}

@Suite struct SpringTests {
    /// The analytical solution satisfies x'' = −ω²x − 2ζωx' for all three damping regimes.
    @Test(arguments: [0.4, 1.0, 1.8])
    func solvesTheOscillatorEquation(damping: Double) {
        let spring = Spring(response: 0.3, dampingRatio: damping)
        let omega = spring.angularFrequency
        let x0 = 100.0, v0 = -250.0
        for t in [0.01, 0.05, 0.12, 0.3] {
            let r = spring.response(at: t)
            let h = 1e-5
            let next = spring.response(at: t + h), previous = spring.response(at: t - h)
            let x = x0 * r.f + v0 * r.g
            let v = x0 * r.df + v0 * r.dg
            let acceleration = ((x0 * next.df + v0 * next.dg) - (x0 * previous.df + v0 * previous.dg)) / (2 * h)
            let numericVelocity = ((x0 * next.f + v0 * next.g) - (x0 * previous.f + v0 * previous.g)) / (2 * h)
            #expect(abs(v - numericVelocity) < 1e-3)
            #expect(abs(acceleration - (-omega * omega * x - 2 * damping * omega * v)) < 1e-1)
        }
        let initial = spring.response(at: 0)
        #expect(abs(initial.f - 1) < 1e-12 && abs(initial.g) < 1e-12)
        #expect(abs(initial.df) < 1e-12 && abs(initial.dg - 1) < 1e-12)
    }

    @Test(arguments: [0.5, 1.0, 1.5])
    func settlesWithinTolerance(damping: Double) {
        let spring = Spring(response: 0.3, dampingRatio: damping)
        let displacement = SIMD4<Double>(-800, 300, 0, 50), velocity = SIMD4<Double>(0, 2000, 0, 0)
        let settle = spring.settlingTime(displacement: displacement, velocity: velocity)
        #expect(settle > 0.1 && settle < 3)
        for t in stride(from: settle, to: settle + 2, by: 0.01) {
            let state = spring.state(at: t, displacement: displacement, velocity: velocity)
            #expect(pointwiseMax(state.displacement, -state.displacement).max() < 0.5)
        }
        let before = spring.state(at: settle * 0.8, displacement: displacement, velocity: velocity)
        let amplitude = before.displacement * before.displacement
            + (before.velocity / spring.angularFrequency) * (before.velocity / spring.angularFrequency)
        #expect(amplitude.max() >= 0.25)
    }

    @Test func underdampedOvershootsCriticalDoesNot() {
        let bouncy = Spring(response: 0.3, dampingRatio: 0.5)
        let critical = Spring(response: 0.3, dampingRatio: 1)
        let bouncyMin = stride(from: 0.0, to: 1, by: 0.005).map { bouncy.response(at: $0).f }.min()!
        let criticalMin = stride(from: 0.0, to: 1, by: 0.005).map { critical.response(at: $0).f }.min()!
        #expect(bouncyMin < -0.1)
        #expect(criticalMin > -1e-9)
    }

    @Test func alreadySettledHasZeroSettlingTime() {
        let spring = Spring(response: 0.3, dampingRatio: 1)
        #expect(spring.settlingTime(displacement: SIMD4(0.1, 0, 0, 0), velocity: .zero) == 0)
    }
}
