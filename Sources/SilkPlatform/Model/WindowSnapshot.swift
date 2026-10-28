import CoreGraphics
import Foundation

/// How a window participates in layout, as decided by ``WindowClassifier``.
public enum WindowKind: String, Sendable, Equatable {
    /// A regular window: tiled by default.
    case window
    /// A dialog-like window: floated by default.
    case dialog
    /// Not a real window (tooltips, menus, quick terminals, …): ignored by layout.
    case popup
}

/// Value snapshot of a window, read on its app's thread.
public struct WindowSnapshot: Sendable, Equatable {
    public var id: UInt32
    public var pid: pid_t
    public var bundleId: String?
    public var appName: String?
    /// Often empty right after creation; updates arrive as ``PlatformEvent/windowTitleChanged(_:_:)``.
    public var title: String
    /// Global top-left-origin frame; nil when the app didn't report position or size.
    public var frame: CGRect?
    public var kind: WindowKind
    public var isMinimized: Bool
    public var isFullscreen: Bool
    public var isFocused: Bool
    public var isMain: Bool
    /// Window-server layer (`kCGWindowLayer`). nil = not on screen yet; the window is
    /// classified as such and re-classified (``PlatformEvent/windowReclassified(_:)``) once it is.
    public var level: Int?
    /// The left mouse button was down when the window was detected. Typically a tab being
    /// dragged out of a browser: the engine should defer laying out this window until mouse-up.
    public var createdDuringMouseDrag: Bool
    public var subrole: String?
    public var identifier: String?
    /// The app has no Dock icon (activation policy `.accessory`): typically a menu bar app.
    public var isAccessoryApp: Bool

    public init(
        id: UInt32, pid: pid_t, bundleId: String?, appName: String?, title: String, frame: CGRect?,
        kind: WindowKind, isMinimized: Bool, isFullscreen: Bool, isFocused: Bool, isMain: Bool,
        level: Int?, createdDuringMouseDrag: Bool, subrole: String?, identifier: String?, isAccessoryApp: Bool = false
    ) {
        self.id = id
        self.pid = pid
        self.bundleId = bundleId
        self.appName = appName
        self.title = title
        self.frame = frame
        self.kind = kind
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.isFocused = isFocused
        self.isMain = isMain
        self.level = level
        self.createdDuringMouseDrag = createdDuringMouseDrag
        self.subrole = subrole
        self.identifier = identifier
        self.isAccessoryApp = isAccessoryApp
    }
}
