import Foundation

/// A CSS-style cubic bezier timing curve from (0, 0) to (1, 1) with control points
/// (x1, y1) and (x2, y2), solved like WebKit's `UnitBezier`: Newton–Raphson on x(t),
/// falling back to bisection when the derivative vanishes or Newton does not converge.
///
/// `x1`/`x2` are clamped to [0, 1] so x(t) is monotonic; `y1`/`y2` are unrestricted, so
/// curves like Hyprland's `0.05, 0.9, 0.1, 1.05` overshoot past 1.
public struct UnitBezier: Equatable, Sendable {
    public let x1: Double, y1: Double, x2: Double, y2: Double

    private let ax: Double, bx: Double, cx: Double
    private let ay: Double, by: Double, cy: Double

    public init(x1: Double, y1: Double, x2: Double, y2: Double) {
        self.x1 = min(max(x1, 0), 1)
        self.y1 = y1
        self.x2 = min(max(x2, 0), 1)
        self.y2 = y2
        // Polynomial coefficients of B(t) = ((a·t + b)·t + c)·t with P0 = 0 and P3 = 1.
        cx = 3 * self.x1
        bx = 3 * (self.x2 - self.x1) - cx
        ax = 1 - cx - bx
        cy = 3 * y1
        by = 3 * (y2 - y1) - cy
        ay = 1 - cy - by
    }

    /// Progress y for elapsed fraction `x` (clamped to [0, 1]).
    public func value(at x: Double) -> Double {
        sampleY(solveT(forX: min(max(x, 0), 1)))
    }

    /// dy/dx at elapsed fraction `x`; multiply by `1 / duration` for progress per second.
    public func slope(at x: Double) -> Double {
        // dx/dt is 0 at t = 0 when x1 = 0 (and at t = 1 when x2 = 1); sample just inside.
        let t = min(max(solveT(forX: min(max(x, 0), 1)), 1e-4), 1 - 1e-4)
        let dx = sampleDerivativeX(t)
        return abs(dx) < 1e-9 ? 0 : sampleDerivativeY(t) / dx
    }

    private func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func sampleDerivativeX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }
    private func sampleDerivativeY(_ t: Double) -> Double { (3 * ay * t + 2 * by) * t + cy }

    // Tight: near a vertical start (x1 = 0) a small x error is a large y error.
    private static let epsilon = 1e-10

    private func solveT(forX x: Double) -> Double {
        var t = x
        for _ in 0..<8 {
            let error = sampleX(t) - x
            if abs(error) < Self.epsilon { return t }
            let derivative = sampleDerivativeX(t)
            if abs(derivative) < 1e-6 { break }
            t -= error / derivative
        }
        var low = 0.0, high = 1.0
        t = x
        while low < high {
            let sample = sampleX(t)
            if abs(sample - x) < Self.epsilon { return t }
            if x > sample { low = t } else { high = t }
            let next = (low + high) / 2
            if next == t { break }
            t = next
        }
        return t
    }
}
