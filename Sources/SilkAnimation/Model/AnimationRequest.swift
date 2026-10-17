import CoreGraphics
import Foundation

/// A batch of frame changes for one layout epoch, built by the Engine from a `LayoutPlan`.
/// All frames are global top-left-origin points.
public struct AnimationRequest: Equatable, Sendable {
    /// One window to animate.
    public struct Move: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// Tile change; animates position and size.
            case layout
            /// Newly placed window. `.move` animates from `from` (the app's initial frame);
            /// `.popIn` starts at a scaled-down copy of `to` centred on it and grows, unless the
            /// app's size writes are too slow, in which case it behaves like `.move`.
            case open(OpenStyle)
            /// Workspace switch: position-only slides. A size change is applied with the
            /// first write (while the window is still parked), before it slides.
            case workspaceIn, workspaceOut
        }

        public enum OpenStyle: Equatable, Sendable { case move, popIn }

        public var window: UInt32
        /// Owning process; windows of one app share that app's per-tick write budget.
        public var pid: pid_t
        /// Where the window is now. Ignored when the window is already animating: the
        /// animator retargets from its presented frame instead.
        public var from: CGRect
        public var to: CGRect
        public var kind: Kind
        /// Display whose refresh drives this tween (normally the screen containing `to`).
        public var displayID: CGDirectDisplayID
        /// Follow-up frame: when the tween completes, the final write goes here instead of
        /// `to` (e.g. the hide corner after a workspace slide-out). Dropped if a newer
        /// request retargets or snaps the window first.
        public var then: CGRect?

        public init(
            window: UInt32, pid: pid_t, from: CGRect, to: CGRect, kind: Kind,
            displayID: CGDirectDisplayID, then: CGRect? = nil
        ) {
            self.window = window
            self.pid = pid
            self.from = from
            self.to = to
            self.kind = kind
            self.displayID = displayID
            self.then = then
        }

        /// The frame the window rests at once this move completes.
        public var restingFrame: CGRect { then ?? to }
    }

    /// A window to put at `frame` immediately (one final write), cancelling any tween.
    public struct Snap: Equatable, Sendable {
        public var window: UInt32
        public var frame: CGRect
        public init(window: UInt32, frame: CGRect) {
            self.window = window
            self.frame = frame
        }
    }

    public var epoch: UInt64
    public var moves: [Move]
    public var snaps: [Snap]

    public init(epoch: UInt64, moves: [Move] = [], snaps: [Snap] = []) {
        self.epoch = epoch
        self.moves = moves
        self.snaps = snaps
    }
}

/// A window whose animation reached its final write for `epoch`.
public struct AnimationCompletion: Equatable, Sendable {
    public var window: UInt32
    public var epoch: UInt64
    public init(window: UInt32, epoch: UInt64) {
        self.window = window
        self.epoch = epoch
    }
}
