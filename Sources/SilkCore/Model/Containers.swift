import CoreGraphics
import SilkConfig

/// A container of tiled children laid out as `tiles` or `accordion` along its orientation.
final class TilingContainer: TreeNode {
    private(set) var orientation: Orientation
    var layout: ContainerLayout

    init(parent: TreeNode, adaptiveWeight: CGFloat, _ orientation: Orientation, _ layout: ContainerLayout, index: Int) {
        self.orientation = orientation
        self.layout = layout
        super.init(adaptiveWeight: adaptiveWeight)
        bind(to: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    var isRootContainer: Bool { parent is Workspace }

    /// Changes the orientation; with opposite-orientation normalization, ancestors alternate from here up.
    func changeOrientation(_ target: Orientation, normalizeOppositeOrientation: Bool) {
        if orientation == target { return }
        if normalizeOppositeOrientation {
            var next = target
            var node: TreeNode? = self
            while let current = node {
                if let container = current as? TilingContainer {
                    container.orientation = next
                    next = next.opposite
                }
                node = current.parent
            }
        } else {
            orientation = target
        }
    }

    func normalizeOppositeOrientationForNestedContainers() {
        if orientation == (parent as? TilingContainer)?.orientation {
            orientation = orientation.opposite
        }
        for case let child as TilingContainer in children {
            child.normalizeOppositeOrientationForNestedContainers()
        }
    }
}

/// Floating windows of a workspace.
final class FloatingWindowsContainer: TreeNode {
    init(parent: Workspace) {
        super.init(adaptiveWeight: 1)
        bind(to: parent, adaptiveWeight: 1, index: indexBindLast)
    }
}

/// Windows of a workspace that are in macOS native fullscreen.
final class MacosFullscreenWindowsContainer: TreeNode {
    init(parent: Workspace) {
        super.init(adaptiveWeight: 1)
        bind(to: parent, adaptiveWeight: 1, index: indexBindLast)
    }
}

/// Windows of a workspace whose app is hidden (cmd-h).
final class MacosHiddenAppsWindowsContainer: TreeNode {
    init(parent: Workspace) {
        super.init(adaptiveWeight: 1)
        bind(to: parent, adaptiveWeight: 1, index: indexBindLast)
    }
}

/// Minimized windows. Global: they don't belong to any workspace.
final class MacosMinimizedWindowsContainer: TreeNode {
    init() { super.init(adaptiveWeight: 1) }
}

/// Objects that are windows for AX but not for humans (e.g. the keyboard layout switcher). Global.
final class MacosPopupWindowsContainer: TreeNode {
    init() { super.init(adaptiveWeight: 1) }
}

/// The kind of container a window was in before macOS moved it into a special state.
enum NonLeafNodeKind: String, Codable, Equatable {
    case tilingContainer, workspace, floatingWindowsContainer
    case macosMinimizedWindowsContainer, macosHiddenAppsWindowsContainer
    case macosFullscreenWindowsContainer, macosPopupWindowsContainer

    init?(_ node: TreeNode) {
        switch node {
            case is TilingContainer: self = .tilingContainer
            case is Workspace: self = .workspace
            case is FloatingWindowsContainer: self = .floatingWindowsContainer
            case is MacosMinimizedWindowsContainer: self = .macosMinimizedWindowsContainer
            case is MacosHiddenAppsWindowsContainer: self = .macosHiddenAppsWindowsContainer
            case is MacosFullscreenWindowsContainer: self = .macosFullscreenWindowsContainer
            case is MacosPopupWindowsContainer: self = .macosPopupWindowsContainer
            default: return nil
        }
    }
}

/// How a child relates to its parent. Nil from the initializer means the relation is illegal.
enum ChildParentRelation {
    case floatingWindow
    case macosNativeFullscreenWindow
    case macosNativeHiddenAppWindow
    case macosNativeMinimizedWindow
    case macosPopupWindow
    case tiling(TilingContainer)
    case rootTilingContainer
    /// A special container directly under its workspace.
    case shimContainer

    init?(child: TreeNode, parent: TreeNode) {
        switch (child, parent) {
            case (is Workspace, _): return nil
            case (is Window, is Workspace): return nil
            case (is Window, is MacosPopupWindowsContainer): self = .macosPopupWindow
            case (is Window, is MacosMinimizedWindowsContainer): self = .macosNativeMinimizedWindow
            case (is Window, is FloatingWindowsContainer): self = .floatingWindow
            case (is Window, is MacosFullscreenWindowsContainer): self = .macosNativeFullscreenWindow
            case (is Window, is MacosHiddenAppsWindowsContainer): self = .macosNativeHiddenAppWindow
            case (is Window, let container as TilingContainer), (is TilingContainer, let container as TilingContainer):
                self = .tiling(container)
            case (is TilingContainer, is Workspace): self = .rootTilingContainer
            case (is FloatingWindowsContainer, is Workspace), (is MacosFullscreenWindowsContainer, is Workspace),
                 (is MacosHiddenAppsWindowsContainer, is Workspace):
                self = .shimContainer
            default: return nil
        }
    }
}
