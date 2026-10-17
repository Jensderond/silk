import CoreGraphics

/// A CGWindowID.
public typealias WindowID = UInt32
/// A display UUID string; stable across reconnects.
public typealias MonitorID = String

/// A connected display, in global top-left-origin coordinates.
public struct Monitor: Equatable, Sendable {
    public var id: MonitorID
    /// The localized display name, e.g. "Built-in Retina Display".
    public var name: String
    public var frame: CGRect
    /// The frame minus menu bar and Dock.
    public var visibleFrame: CGRect
    /// The display with the menu bar at the origin of the global coordinate space.
    public var isMain: Bool

    public init(id: MonitorID, name: String, frame: CGRect, visibleFrame: CGRect, isMain: Bool) {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isMain = isMain
    }
}
