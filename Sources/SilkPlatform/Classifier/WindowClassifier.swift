import ApplicationServices

/// The AX attributes the classifier looks at, captured once per window.
public struct AXWindowDump: Sendable, Equatable {
    /// A titlebar button (`AXCloseButton`, …). `isEnabled` is nil when `AXEnabled` wasn't read or failed.
    public struct Button: Sendable, Equatable {
        public var isEnabled: Bool?
        public init(isEnabled: Bool?) { self.isEnabled = isEnabled }
    }

    public var windowID: UInt32?
    public var subrole: String?
    public var title: String?
    public var identifier: String?
    public var isFocused: Bool?
    public var isMain: Bool?
    public var closeButton: Button?
    public var fullscreenButton: Button?
    public var zoomButton: Button?
    public var minimizeButton: Button?
    /// Window id of the app's `AXFocusedWindow`.
    public var appFocusedWindowID: UInt32?
    /// `kCGWindowLayer`; nil when the window is not on screen. 0 = normal, 3 = always-on-top.
    public var windowLevel: Int?

    public init(
        windowID: UInt32? = nil, subrole: String? = nil, title: String? = nil, identifier: String? = nil,
        isFocused: Bool? = nil, isMain: Bool? = nil, closeButton: Button? = nil, fullscreenButton: Button? = nil,
        zoomButton: Button? = nil, minimizeButton: Button? = nil, appFocusedWindowID: UInt32? = nil, windowLevel: Int? = nil
    ) {
        self.windowID = windowID
        self.subrole = subrole
        self.title = title
        self.identifier = identifier
        self.isFocused = isFocused
        self.isMain = isMain
        self.closeButton = closeButton
        self.fullscreenButton = fullscreenButton
        self.zoomButton = zoomButton
        self.minimizeButton = minimizeButton
        self.appFocusedWindowID = appFocusedWindowID
        self.windowLevel = windowLevel
    }

    var hasNoButtons: Bool {
        closeButton == nil && fullscreenButton == nil && zoomButton == nil && minimizeButton == nil
    }
}

/// The app-level facts the classifier depends on.
public struct AppTraits: Sendable, Equatable {
    public var bundleId: String?
    public var activationPolicy: AppActivationPolicy

    public init(bundleId: String?, activationPolicy: AppActivationPolicy) {
        self.bundleId = bundleId
        self.activationPolicy = activationPolicy
    }
}

/// Titlebar buttons whose `AXEnabled` state the classifier reads.
enum WindowButton: CaseIterable {
    case close, fullscreen, zoom, minimize
}

/// Pure port of AeroSpace's `AxUiElementWindowType` heuristics (`isWindowHeuristic`,
/// `isDialogHeuristic`, `KnownBundleId` special cases), verified against AeroSpace's axDumps corpus.
public enum WindowClassifier {
    private static let normalWindowLevel = 0

    public static func classify(_ dump: AXWindowDump, app: AppTraits) -> WindowKind {
        let id = app.bundleId.flatMap(KnownBundleID.init(rawValue:))
        if !isWindow(dump, id, app.activationPolicy) { return .popup }
        if isDialog(dump, id) { return .dialog }
        return .window
    }

    /// Buttons whose `AXEnabled` the classifier consults for this app; the snapshot reader only
    /// reads those (each one is an extra AX round trip).
    static func buttonsNeedingEnabledState(bundleId: String?) -> Set<WindowButton> {
        let id = bundleId.flatMap(KnownBundleID.init(rawValue:))
        var result: Set<WindowButton> = [.fullscreen]
        if id == .ghostty { result.insert(.close) }
        if id?.isFirefox == true { result.insert(.minimize) }
        return result
    }

    /// Whether the classifier may consult the app's focused window for this dump.
    static func needsAppFocusedWindow(_ dump: AXWindowDump) -> Bool {
        dump.hasNoButtons && dump.isFocused != true && dump.isMain != true
    }

    static func isDialog(_ dump: AXWindowDump, app: AppTraits) -> Bool {
        isDialog(dump, app.bundleId.flatMap(KnownBundleID.init(rawValue:)))
    }

    // Note: a lot of windows don't have title on startup. So please don't rely on the title
    private static func isDialog(_ dump: AXWindowDump, _ id: KnownBundleID?) -> Bool {
        if id == ._1password && dump.windowLevel != normalWindowLevel {
            return true
        }
        if id == .iphonesimulator {
            return true
        }
        // Don't tile: Chrome cmd+f window ("AXUnknown"), login screen ("AXUnknown"), Xcode "Build succeeded"
        // popup, IntelliJ tooltips/context menus/drop downs, macOS native file picker (kAXDialogSubrole).
        // Minimized windows or windows of a hidden app have subrole "AXDialog".
        // qutebrowser regular window has AXDialog subrole when decorations are disabled.
        if dump.subrole != kAXStandardWindowSubrole && id != .qutebrowser {
            return true
        }
        // Firefox: Picture in Picture window doesn't have minimize button.
        if id?.isFirefox == true && dump.minimizeButton?.isEnabled != true {
            return true
        }
        if id == .photoBooth { return true }
        if id == .ghostty {
            return dump.fullscreenButton?.isEnabled != true && dump.closeButton?.isEnabled == true
        }
        // Float windows without (enabled) fullscreen button: such windows are not designed to be big
        // (IntelliJ dialogs, Finder copy dialog, System Settings, About this Mac, Calculator, …).
        if dump.fullscreenButton?.isEnabled != true &&
            id != .gimp && // Gimp doesn't show fullscreen button
            // Tab dragged out of Chrome: race between mouse-up and Chrome re-enabling the fullscreen button
            id != .chrome &&
            id != .activityMonitor && // Activity Monitor doesn't show fullscreen button
            // Terminal apps and Emacs have an option to hide their title bars
            id != .alacritty &&
            id != .kitty &&
            id != .wezterm &&
            id != .qutebrowser &&
            id != .iterm2 &&
            id != .emacs &&
            id?.isVscode != true && // "window.nativeFullScreen": false
            id != .steam
        {
            return true
        }
        return false
    }

    static func isWindow(_ dump: AXWindowDump, app: AppTraits) -> Bool {
        isWindow(dump, app.bundleId.flatMap(KnownBundleID.init(rawValue:)), app.activationPolicy)
    }

    /// Alternative name: !isPopup. Filters out non-windows for the "floating by default" workflow
    /// and so that focus commands don't treat popups as floating windows.
    private static func isWindow(_ dump: AXWindowDump, _ id: KnownBundleID?, _ activationPolicy: AppActivationPolicy) -> Bool {
        if dump.windowLevel != normalWindowLevel &&
            // AeroSpace rolls out the window-level check only for apps with appropriate dumps
            (id == .slack || id == .chrome || id?.isFirefox == true || id == .braveBrowser || id == .screenstudio ||
                id == .cleanshotx || id == .iterm2 || id == .outlook || id == .codex || id == .wisprFlow)
        {
            return false
        }
        // "Ghostty Quick Terminal": position and size are managed by Ghostty itself (AeroSpace #103)
        if id == .ghostty && dump.identifier == "com.mitchellh.ghostty.quickTerminal" {
            return false
        }
        if id == .xcode && dump.identifier == "open_quickly" {
            return false
        }
        if id == .iterm2 && dump.fullscreenButton == nil {
            return false
        }
        if activationPolicy == .accessory && dump.closeButton == nil && id != .steam {
            return false
        }
        // Emacs child frames (posframes, corfu completion popups, …) (AeroSpace #776)
        if id == .emacs && dump.subrole == kAXFloatingWindowSubrole {
            return false
        }
        if id?.isFirefox != true {
            return isWindowLegacy(dump, id)
        }
        // Filter out weird popup-like AXWindows without any buttons (keyboard layout switch, context menus,
        // screen-share "pill", link/button tooltips) while keeping file pickers, image viewers, Quick Look
        // and Firefox non-native fullscreen.
        return dump.closeButton != nil ||
            dump.fullscreenButton != nil ||
            dump.zoomButton != nil ||
            dump.minimizeButton != nil ||
            dump.isFocused == true ||
            dump.isMain == true ||
            dump.appFocusedWindowID == dump.windowID ||
            dump.subrole == kAXStandardWindowSubrole
    }

    /// AeroSpace's `isWindowHeuristicOld` (0.18.3 hotfix), still used for everything but Firefox.
    private static func isWindowLegacy(_ dump: AXWindowDump, _ id: KnownBundleID?) -> Bool {
        let subrole = dump.subrole
        let title = dump.title ?? ""
        if dump.hasNoButtons &&
            dump.isFocused == false &&
            dump.isMain == false &&
            dump.appFocusedWindowID != dump.windowID &&
            subrole != kAXStandardWindowSubrole &&
            // Screen-share purple "pill" indicator has "Window" title (AeroSpace #1101)
            (title.isEmpty || title == "Window")
        {
            return false
        }
        return subrole == kAXStandardWindowSubrole ||
            subrole == kAXDialogSubrole || // macOS native file picker
            subrole == kAXFloatingWindowSubrole || // Telegram image viewer
            id == .finder && subrole == "Quick Look" // Finder preview (space)
    }
}
