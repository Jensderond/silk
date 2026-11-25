/// Turns trackpad frames into three-finger horizontal swipes: one swipe per time the fingers go down.
public struct SwipeRecognizer {
    public enum Direction: Equatable, Sendable { case left, right }

    /// How far the fingers travel before it counts, as a share of the trackpad's width.
    static let distance: Float = 0.12

    private var start: (x: Float, y: Float)?
    /// A swipe was reported, or a fourth finger joined: nothing more until every finger is up.
    private var isSpent = false

    public init() {}

    /// Feeds one frame: the number of touching fingers and their average position (0…1).
    public mutating func feed(fingers: Int, x: Float, y: Float) -> Direction? {
        switch fingers {
            case 0:
                start = nil
                isSpent = false
            case 3 where !isSpent:
                guard let start else {
                    start = (x, y)
                    return nil
                }
                let dx = x - start.x, dy = y - start.y
                if abs(dx) >= Self.distance, abs(dx) > 2 * abs(dy) {
                    isSpent = true
                    return dx < 0 ? .left : .right
                }
            case 4...:
                isSpent = true
            default:
                // One or two fingers: the average jumps when the third lands, so measure from there.
                start = nil
        }
        return nil
    }
}
