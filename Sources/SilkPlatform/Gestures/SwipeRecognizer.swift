/// Turns trackpad frames into a three-finger horizontal swipe that is tracked while the fingers are down and
/// decided when they lift: it commits only if, at that moment, it is still past the commit threshold. Sliding
/// back below the threshold before lifting cancels it.
public struct SwipeRecognizer {
    public enum Direction: Equatable, Sendable { case left, right }

    public enum Event: Equatable, Sendable {
        /// Three fingers moved far enough sideways to count as a swipe.
        case began(progress: Float)
        case changed(progress: Float)
        /// The fingers lifted past the commit threshold.
        case ended(Direction)
        /// The fingers lifted short of the threshold, a fourth finger joined, or tracking was interrupted.
        case cancelled
    }

    /// How far the fingers travel, as a share of the trackpad's width, for a progress of ±1.
    static let fullTravel: Float = 0.24
    /// The share of `fullTravel` past which lifting the fingers commits: 0.12 of the trackpad's width.
    public static let commitThreshold: Float = 0.5
    /// How far the fingers move before deciding between a horizontal swipe and something else.
    static let slop: Float = 0.02

    /// Whether lifting the fingers at `progress` commits the swipe.
    public static func commits(_ progress: Float) -> Bool { abs(progress) >= commitThreshold }

    /// Where three fingers first touched, or nil while fewer do.
    private var anchor: (x: Float, y: Float)?
    private var isTracking = false
    /// The progress of the last three-finger frame; lifting moves the average, so that is what counts.
    private var progress: Float = 0
    /// The fingers moved vertically, a fourth one joined or a swipe ended: nothing until every finger is up.
    private var isSpent = false

    public init() {}

    public var isActive: Bool { isTracking }

    /// Feeds one frame: the number of touching fingers and their average position (0…1).
    public mutating func feed(fingers: Int, x: Float, y: Float) -> Event? {
        switch fingers {
            case 3:
                guard !isSpent else { return nil }
                guard let anchor else {
                    anchor = (x, y)
                    return nil
                }
                let dx = x - anchor.x, dy = y - anchor.y
                let next = min(max(dx / Self.fullTravel, -1), 1)
                if isTracking {
                    guard next != progress else { return nil }
                    progress = next
                    return .changed(progress: next)
                }
                if abs(dy) >= Self.slop, abs(dy) >= abs(dx) {
                    isSpent = true // Vertical: Mission Control and friends
                    return nil
                }
                guard abs(dx) >= Self.slop, abs(dx) > 2 * abs(dy) else { return nil }
                isTracking = true
                progress = next
                return .began(progress: next)
            case 4...:
                isSpent = true
                return finish(commit: false)
            default:
                // Fewer than three: the fingers are lifting (one at a time, so this comes before zero) or the
                // third hasn't landed yet; the average jumps when it does, so measure from there.
                anchor = nil
                let event = finish(commit: true)
                if fingers == 0 { isSpent = false }
                return event
        }
    }

    /// Ends tracking without committing and starts over, e.g. when frames stop arriving (the next ones may
    /// belong to a new touch, without a zero-finger frame in between). Nil when not tracking.
    public mutating func cancel() -> Event? {
        defer { self = SwipeRecognizer() }
        return finish(commit: false)
    }

    private mutating func finish(commit: Bool) -> Event? {
        guard isTracking else { return nil }
        isTracking = false
        isSpent = true
        guard commit, Self.commits(progress) else { return .cancelled }
        return .ended(progress < 0 ? .left : .right)
    }
}
