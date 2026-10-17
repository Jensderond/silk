import CoreGraphics

// All rects are in global top-left-origin coordinates: `minY` is the top edge.

extension CGRect {
    /// A rect whose negative dimensions are clamped to zero (AeroSpace `Rect` semantics).
    init(topLeftX x: CGFloat, topLeftY y: CGFloat, width: CGFloat, height: CGFloat) {
        self.init(x: x, y: y, width: max(width, 0), height: max(height, 0))
    }

    var topLeftCorner: CGPoint { CGPoint(x: minX, y: minY) }
    var bottomLeftCorner: CGPoint { CGPoint(x: minX, y: maxY) }
    var bottomRightCorner: CGPoint { CGPoint(x: maxX, y: maxY) }
    var center: CGPoint { CGPoint(x: minX + width / 2, y: minY + height / 2) }

    func dimension(_ orientation: Orientation) -> CGFloat { orientation == .h ? width : height }

    /// Half-open containment (`min <= p < max`), matching AeroSpace.
    func containsPoint(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }
}

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }

    var vectorLength: CGFloat { (x * x + y * y).squareRoot() }

    func projection(_ orientation: Orientation) -> CGFloat { orientation == .h ? x : y }

    func addingOffset(_ orientation: Orientation, _ offset: CGFloat) -> CGPoint {
        orientation == .h ? CGPoint(x: x + offset, y: y) : CGPoint(x: x, y: y + offset)
    }

    /// Distance to the nearest point of `rect` (zero inside); right/bottom bounds are exclusive.
    func distance(toOuterFrame rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - x, 0, x - (rect.maxX - 1))
        let dy = max(rect.minY - y, 0, y - (rect.maxY - 1))
        return CGPoint(x: dx, y: dy).vectorLength
    }

    /// The closest point inside `rect`, or nil for an empty rect.
    func coerced(in rect: CGRect) -> CGPoint? {
        guard rect.maxX - 1 >= rect.minX, rect.maxY - 1 >= rect.minY else { return nil }
        return CGPoint(x: x.coerced(in: rect.minX ... rect.maxX - 1), y: y.coerced(in: rect.minY ... rect.maxY - 1))
    }
}

extension CGFloat {
    func coerced(in range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }

    func divided(by denominator: Int) -> CGFloat? {
        denominator == 0 ? nil : self / CGFloat(denominator)
    }
}
