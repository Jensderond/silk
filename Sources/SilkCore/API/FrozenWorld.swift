import CoreGraphics

/// A serializable snapshot of the window manager's layout, for restoring after a crash or upgrade.
/// Windows are referenced by id; restoring re-binds each window when it is detected again.
public struct FrozenWorld: Codable, Equatable, Sendable {
    public var workspaces: [FrozenWorkspace]
    /// Monitor id → name of the workspace it showed.
    public var visibleWorkspaces: [MonitorID: String]
    public var focusedWorkspace: String
    public var focusedWindowId: WindowID?

    public init(workspaces: [FrozenWorkspace], visibleWorkspaces: [MonitorID: String], focusedWorkspace: String, focusedWindowId: WindowID?) {
        self.workspaces = workspaces
        self.visibleWorkspaces = visibleWorkspaces
        self.focusedWorkspace = focusedWorkspace
        self.focusedWindowId = focusedWindowId
    }

    /// Every window id in the snapshot.
    public var windowIds: Set<WindowID> {
        Set(workspaces.flatMap { $0.root.windowIds + $0.floatingWindows.map(\.id) + $0.macosUnconventionalWindows.map(\.id) })
    }
}

public struct FrozenWorkspace: Codable, Equatable, Sendable {
    public var name: String
    /// The monitor the workspace was last shown on.
    public var monitorId: MonitorID?
    public var root: FrozenContainer
    public var floatingWindows: [FrozenWindow]
    /// macOS native fullscreen and hidden-app windows; restored as floating, then normalized back.
    public var macosUnconventionalWindows: [FrozenWindow]

    public init(name: String, monitorId: MonitorID?, root: FrozenContainer, floatingWindows: [FrozenWindow], macosUnconventionalWindows: [FrozenWindow]) {
        self.name = name
        self.monitorId = monitorId
        self.root = root
        self.floatingWindows = floatingWindows
        self.macosUnconventionalWindows = macosUnconventionalWindows
    }
}

public struct FrozenContainer: Codable, Equatable, Sendable {
    public enum Layout: String, Codable, Sendable { case tiles, accordion }
    public enum Orientation: String, Codable, Sendable { case horizontal, vertical }

    public var layout: Layout
    public var orientation: Orientation
    /// Weight along the parent's orientation (1 for the root container).
    public var weight: Double
    public var children: [FrozenNode]

    public init(layout: Layout, orientation: Orientation, weight: Double, children: [FrozenNode]) {
        self.layout = layout
        self.orientation = orientation
        self.weight = weight
        self.children = children
    }

    var windowIds: [WindowID] {
        children.flatMap { child -> [WindowID] in
            switch child {
                case .window(let window): [window.id]
                case .container(let container): container.windowIds
            }
        }
    }
}

public indirect enum FrozenNode: Codable, Equatable, Sendable {
    case container(FrozenContainer)
    case window(FrozenWindow)
}

public struct FrozenWindow: Codable, Equatable, Sendable {
    public var id: WindowID
    /// Weight along the parent's orientation (1 outside tiling containers).
    public var weight: Double
    /// The window's on-screen frame (where it returns to when unhidden), kept for floating windows.
    public var frame: CGRect?
    public var lastFloatingSize: CGSize?

    public init(id: WindowID, weight: Double, frame: CGRect? = nil, lastFloatingSize: CGSize? = nil) {
        self.id = id
        self.weight = weight
        self.frame = frame
        self.lastFloatingSize = lastFloatingSize
    }
}
