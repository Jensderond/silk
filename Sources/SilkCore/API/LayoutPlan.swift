import CoreGraphics

/// The desired physical state of every managed window, computed by `WindowManager.computeLayout()`.
/// The plan is complete (not a diff): the engine diffs it against what it last applied.
public struct LayoutPlan: Equatable, Sendable {
    /// Monotonic per `computeLayout()` call; tags frame writes so stale ones can be dropped.
    public var epoch: UInt64
    /// Target frames of tiling and floating windows on visible workspaces.
    public var frames: [WindowID: CGRect]
    /// Windows of invisible workspaces and where to park them.
    public var hidden: [WindowID: HideTarget]
    /// Windows placed for the first time in this plan, with the frame the app opened them at (animation start).
    public var newlyPlaced: [WindowID: CGRect]
    /// Windows moving because of an in-progress mouse drag/resize: apply instantly, never animate. The window
    /// under the mouse itself is not in `frames` while the gesture lasts.
    public var userDriven: Set<WindowID>
    /// Monitors whose visible workspace changed since the previous plan.
    public var workspaceSwitches: [WorkspaceSwitch]
    public var focusedWindow: WindowID?

    public init(
        epoch: UInt64,
        frames: [WindowID: CGRect] = [:],
        hidden: [WindowID: HideTarget] = [:],
        newlyPlaced: [WindowID: CGRect] = [:],
        userDriven: Set<WindowID> = [],
        workspaceSwitches: [WorkspaceSwitch] = [],
        focusedWindow: WindowID? = nil
    ) {
        self.epoch = epoch
        self.frames = frames
        self.hidden = hidden
        self.newlyPlaced = newlyPlaced
        self.userDriven = userDriven
        self.workspaceSwitches = workspaceSwitches
        self.focusedWindow = focusedWindow
    }
}

/// The monitor corner a hidden window is parked in (AeroSpace `OptimalHideCorner`).
public enum HideCorner: String, Sendable, Codable {
    case bottomLeft, bottomRight
}

/// Where to park a window of an invisible workspace.
public struct HideTarget: Equatable, Sendable {
    public var monitor: MonitorID
    /// The visible frame of the monitor the window's workspace belongs to.
    public var monitorVisibleRect: CGRect
    public var corner: HideCorner
    /// The top-left point to move the window to, leaving a 1 pt sliver on screen (none for Zoom, which jumps
    /// back otherwise). Bottom-left uses the window's last known width.
    public var origin: CGPoint

    public init(monitor: MonitorID, monitorVisibleRect: CGRect, corner: HideCorner, origin: CGPoint) {
        self.monitor = monitor
        self.monitorVisibleRect = monitorVisibleRect
        self.corner = corner
        self.origin = origin
    }
}

/// A monitor that now shows a different workspace.
public struct WorkspaceSwitch: Equatable, Sendable {
    public var monitor: MonitorID
    public var from: String
    public var to: String
    public var direction: SlideDirection

    public init(monitor: MonitorID, from: String, to: String, direction: SlideDirection) {
        self.monitor = monitor
        self.from = from
        self.to = to
        self.direction = direction
    }
}

/// How a workspace switch slides. Slides never cross into a neighbouring monitor.
public enum SlideDirection: String, Sendable {
    /// Content moves left: the old workspace exits through the left edge, the new one enters from the right.
    case left
    /// Content moves right: the old workspace exits through the right edge, the new one enters from the left.
    case right
    /// Both workspaces use the bottom edge: the old one slides down and out, the new one rises in.
    case down
    /// No free edge: switch instantly.
    case none
}
