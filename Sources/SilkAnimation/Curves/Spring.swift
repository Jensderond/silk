import Foundation

/// A damped harmonic oscillator, parameterised like SwiftUI's springs.
///
/// `response` is the period of the undamped oscillation in seconds (stiffness =
/// (2π / response)²); `dampingRatio` 1 is critically damped, < 1 bounces, > 1 is sluggish.
/// Motion is solved analytically, so evaluation is exact for any `t` and a retarget can
/// start a new spring from the current displacement *and velocity*.
public struct Spring: Equatable, Sendable {
    public let response: Double
    public let dampingRatio: Double

    public init(response: Double, dampingRatio: Double) {
        self.response = max(response, 0.01)
        self.dampingRatio = max(dampingRatio, 0.01)
    }

    /// Undamped angular frequency ω₀ in rad/s.
    public var angularFrequency: Double { 2 * .pi / response }

    /// The linear response of the oscillator at time `t`: displacement(t) = x₀·f + v₀·g and
    /// velocity(t) = x₀·df + v₀·dg for initial displacement x₀ and velocity v₀.
    public struct Response: Equatable, Sendable {
        public var f: Double, g: Double, df: Double, dg: Double
    }

    /// The oscillator's response at `t` seconds after release.
    public func response(at t: Double) -> Response {
        let t = max(t, 0)
        let omega = angularFrequency
        let zeta = dampingRatio
        if abs(zeta - 1) < 1e-4 {
            let decay = exp(-omega * t)
            return Response(
                f: decay * (1 + omega * t),
                g: decay * t,
                df: -omega * omega * t * decay,
                dg: decay * (1 - omega * t)
            )
        }
        if zeta < 1 {
            let alpha = zeta * omega
            let omegaD = omega * (1 - zeta * zeta).squareRoot()
            let decay = exp(-alpha * t)
            let cosine = cos(omegaD * t), sine = sin(omegaD * t)
            return Response(
                f: decay * (cosine + alpha / omegaD * sine),
                g: decay * sine / omegaD,
                df: -decay * sine * omega * omega / omegaD,
                dg: decay * (cosine - alpha / omegaD * sine)
            )
        }
        let root = (zeta * zeta - 1).squareRoot()
        let r1 = -omega * (zeta - root), r2 = -omega * (zeta + root)
        let e1 = exp(r1 * t), e2 = exp(r2 * t)
        let span = r2 - r1
        return Response(
            f: (r2 * e1 - r1 * e2) / span,
            g: (e2 - e1) / span,
            df: r1 * r2 * (e1 - e2) / span,
            dg: (r2 * e2 - r1 * e1) / span
        )
    }

    /// Displacement and velocity of every component at `t` (SIMD-wide `response(at:)`).
    public func state(at t: Double, displacement: SIMD4<Double>, velocity: SIMD4<Double>)
        -> (displacement: SIMD4<Double>, velocity: SIMD4<Double>)
    {
        let r = response(at: t)
        return (displacement * r.f + velocity * r.g, displacement * r.df + velocity * r.dg)
    }

    /// The first time at which every component's amplitude √(x² + (v/ω₀)²) is below
    /// `tolerance` (points). That amplitude is the oscillator's energy norm, which never
    /// increases, so the answer is found by bisection. Capped at 10 s.
    public func settlingTime(displacement: SIMD4<Double>, velocity: SIMD4<Double>, tolerance: Double = 0.5) -> Double {
        let omega = angularFrequency
        func settled(_ t: Double) -> Bool {
            let s = state(at: t, displacement: displacement, velocity: velocity)
            let v = s.velocity / omega
            let amplitude = s.displacement * s.displacement + v * v
            return amplitude.max() < tolerance * tolerance
        }
        if settled(0) { return 0 }
        var high = response
        while !settled(high) {
            if high >= 10 { return 10 }
            high = min(high * 2, 10)
        }
        var low = 0.0
        for _ in 0..<40 where high - low > 1e-4 {
            let mid = (low + high) / 2
            if settled(mid) { high = mid } else { low = mid }
        }
        return high
    }
}
