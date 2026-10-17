import CoreGraphics
import Darwin

/// Why a window currently sits in a special container.
enum LayoutReason: Equatable {
    case standard
    /// macOS native fullscreen, minimize or app hide; remembers where the window was before.
    case macos(prevParentKind: NonLeafNodeKind)
}

/// A managed window: a leaf of the tree.
final class Window: TreeNode {
    let id: WindowID
    let pid: pid_t
    let bundleId: String?
    let appName: String?
    var title: String
    /// Classification from the platform; decides tiling vs floating vs popup on (re)layout.
    var kind: WindowKind

    var lastFloatingSize: CGSize?
    /// AeroSpace's (non-native) `fullscreen` command state.
    var isFullscreen = false
    var noOuterGapsInFullscreen = false
    var layoutReason: LayoutReason = .standard

    /// macOS state as last reported by the platform.
    var isMacosFullscreen = false
    var isMacosMinimized = false

    /// The window's last known physical frame: from detection, our applied frames, the user or the app.
    var lastKnownFrame: CGRect?
    /// The app's initial frame, until the window's first placement is reported in a layout plan.
    var pendingInitialFrame: CGRect?
    /// Set while the window is parked in a hide corner: its top-left as a proportion of the monitor it was on.
    var prevUnhiddenProportionalPosition: CGPoint?
    /// Set while the window is ordered out (alive but off screen) and removed from the tree.
    var orderedOutSlot: OrderedOutSlot?

    init(id: WindowID, pid: pid_t, bundleId: String?, appName: String?, title: String, kind: WindowKind, frame: CGRect?) {
        self.id = id
        self.pid = pid
        self.bundleId = bundleId
        self.appName = appName
        self.title = title
        self.kind = kind
        self.lastFloatingSize = frame?.size
        self.lastKnownFrame = frame
        self.pendingInitialFrame = frame
        super.init(adaptiveWeight: weightDoesntMatter)
    }

    var isHiddenInCorner: Bool { prevUnhiddenProportionalPosition != nil }

    var isFloating: Bool { parent is FloatingWindowsContainer }

    /// Tiled or floating, as opposed to sitting in a macOS special container or being unbound.
    var isConventional: Bool { parent is TilingContainer || parent is FloatingWindowsContainer }
}

extension Window: CustomStringConvertible {
    var description: String { "Window(\(id))" }
}
