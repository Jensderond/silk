import CoreGraphics
import SilkConfig

/// A named workspace: the root of a tree with one tiling root container and optional special containers.
final class Workspace: TreeNode {
    let name: String
    let sortKey: LogicalSegments
    unowned let world: World
    /// The top-left corner of the monitor the workspace was last shown on. Only interpreted while the workspace is
    /// invisible.
    var assignedMonitorPoint: ScreenPoint?

    init(name: String, world: World) {
        self.name = name
        self.sortKey = LogicalSegments(name)
        self.world = world
        super.init(adaptiveWeight: 0)
    }

    /// The root container's weight is the workspace's usable size.
    override func getWeight(_ orientation: Orientation) -> CGFloat {
        world.visibleRectPaddedByOuterGaps(world.monitor(of: self)).dimension(orientation)
    }

    override func setWeight(_ orientation: Orientation, _ newValue: CGFloat) {
        assertionFailure("It's not possible to change weight of Workspace")
    }

    /// The single root tiling container, created on demand with the configured default layout.
    var rootTilingContainer: TilingContainer {
        if let existing = children.lazy.compactMap({ $0 as? TilingContainer }).first { return existing }
        let config = world.config
        let orientation: Orientation = switch config.defaultRootContainerOrientation {
            case .horizontal: .h
            case .vertical: .v
            case .auto:
                world.monitor(of: self).frame.width >= world.monitor(of: self).frame.height ? .h : .v
        }
        return TilingContainer(parent: self, adaptiveWeight: 1, orientation, config.defaultRootContainerLayout, index: indexBindLast)
    }

    var floatingWindowsContainer: FloatingWindowsContainer {
        children.lazy.compactMap { $0 as? FloatingWindowsContainer }.first ?? FloatingWindowsContainer(parent: self)
    }

    var macosFullscreenWindowsContainer: MacosFullscreenWindowsContainer {
        children.lazy.compactMap { $0 as? MacosFullscreenWindowsContainer }.first ?? MacosFullscreenWindowsContainer(parent: self)
    }

    var macosHiddenAppsWindowsContainer: MacosHiddenAppsWindowsContainer {
        children.lazy.compactMap { $0 as? MacosHiddenAppsWindowsContainer }.first ?? MacosHiddenAppsWindowsContainer(parent: self)
    }

    var floatingWindows: [Window] {
        children.lazy.compactMap { $0 as? FloatingWindowsContainer }.first?.children.compactMap { $0 as? Window } ?? []
    }

    /// Unconventional windows kept with the workspace: macOS fullscreen and hidden-app windows.
    var macosUnconventionalWindows: [Window] {
        children.filter { $0 is MacosHiddenAppsWindowsContainer || $0 is MacosFullscreenWindowsContainer }
            .flatMap { $0.children.compactMap { $0 as? Window } }
    }
}

extension Workspace: CustomStringConvertible {
    var description: String { "Workspace(\(name))" }
}

extension Workspace: Comparable {
    static func == (lhs: Workspace, rhs: Workspace) -> Bool { lhs === rhs }
    static func < (lhs: Workspace, rhs: Workspace) -> Bool { lhs.sortKey < rhs.sortKey }
}
