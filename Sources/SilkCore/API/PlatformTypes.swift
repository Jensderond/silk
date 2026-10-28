import CoreGraphics
import Darwin

/// How the platform classified a window (AeroSpace `AxUiElementWindowType`).
public enum WindowKind: String, Sendable, Codable {
    /// A regular window: tiled.
    case window
    /// A dialog, panel or other floating window.
    case dialog
    /// Not a window for humans (tooltips, OSDs, the keyboard layout switcher): tracked but never laid out.
    case popup
}

/// A window snapshot handed to the core when the platform discovers a window.
public struct DetectedWindow: Equatable, Sendable {
    public var id: WindowID
    public var pid: pid_t
    public var bundleId: String?
    public var appName: String?
    public var title: String
    /// The app's initial frame; nil when it couldn't be read.
    public var frame: CGRect?
    public var kind: WindowKind
    public var isMinimized: Bool
    public var isFullscreen: Bool
    /// The window is the focused window of the frontmost app.
    public var isFocused: Bool
    /// The app has no Dock icon (activation policy `.accessory`): typically a menu bar app.
    public var isAccessoryApp: Bool

    public init(
        id: WindowID,
        pid: pid_t,
        bundleId: String?,
        appName: String?,
        title: String = "",
        frame: CGRect?,
        kind: WindowKind = .window,
        isMinimized: Bool = false,
        isFullscreen: Bool = false,
        isFocused: Bool = false,
        isAccessoryApp: Bool = false
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
        self.isAccessoryApp = isAccessoryApp
    }
}

/// A running GUI app, for `list-apps` and the app format variables.
public struct AppInfo: Equatable, Sendable {
    public var pid: pid_t
    public var bundleId: String?
    public var name: String?
    public var execPath: String?
    public var bundlePath: String?
    /// Hidden with cmd-h.
    public var isHidden: Bool

    public init(pid: pid_t, bundleId: String?, name: String?, execPath: String? = nil, bundlePath: String? = nil, isHidden: Bool = false) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
        self.execPath = execPath
        self.bundlePath = bundlePath
        self.isHidden = isHidden
    }
}

/// Output volume state for the `volume` command.
public struct VolumeState: Equatable, Sendable {
    /// 0...1
    public var level: Float
    public var isMuted: Bool

    public init(level: Float, isMuted: Bool) {
        self.level = level
        self.isMuted = isMuted
    }
}

/// The phase of a mouse-driven move/resize of a window.
public enum ManipulationPhase: Sendable {
    case began, changed
    /// The left mouse button was released.
    case ended
}
