import CoreGraphics
import Foundation

/// Phase of a user-driven move/resize (mouse drag on a window).
public enum ManipulationPhase: Sendable, Equatable {
    case began
    case changed
    /// Sent on left-mouse-up with the window's final frame.
    case ended
}

/// Everything SilkPlatform reports to the engine. Always delivered on the main thread.
public enum PlatformEvent: Sendable, Equatable {
    /// A window became known: from `kAXWindowCreated`, from an app-level focused/main-window
    /// change naming an unknown window, or from reconciliation (`discoveredByReconcile`).
    /// Each window id appears at most once until it is destroyed.
    case windowAppeared(WindowSnapshot, discoveredByReconcile: Bool)
    /// A window's kind or level changed after it appeared (typically: it was not on screen yet,
    /// or it was a popup that now looks like a window).
    case windowReclassified(WindowSnapshot)
    /// `kAXUIElementDestroyed`, or an AX read returned `kAXErrorInvalidUIElement`.
    case windowDestroyed(UInt32)
    /// Valid element that left `kAXWindows` and is off screen (other Space, Electron `hide()`, …).
    case windowOrderedOut(UInt32)
    /// A previously ordered-out window is back.
    case windowOrderedIn(UInt32)
    /// The window `snapshot` describes took the place of the first window: a native tab was selected, opened or
    /// closed (each macOS tab is a window of its own; see ``TabHandoff``). The replaced window left `kAXWindows` and
    /// is ordered out (a background tab) or gone (`replacedIsGone`, the tab was closed). The new one was ordered out
    /// before, or is reported for the first time (`isNew`); either way this replaces its
    /// `windowAppeared`/`windowOrderedIn`.
    case windowReplaced(UInt32, by: WindowSnapshot, isNew: Bool, replacedIsGone: Bool)
    case windowTitleChanged(UInt32, String)
    case windowMinimizedChanged(UInt32, Bool)
    case windowFullscreenChanged(UInt32, Bool)
    /// The user is dragging/resizing a focused window with the mouse.
    case userManipulation(UInt32, frame: CGRect, phase: ManipulationPhase)
    /// The window moved/resized and it was neither our own write (echo) nor the user.
    case appChangedFrame(UInt32, CGRect)
    /// Read-back after a ``FrameWrite/Mode/final`` write: the frame the app actually accepted.
    case frameApplied(UInt32, CGRect)
    /// AX confirmation of focus: the app's focused window changed (nil = no window, e.g. Finder desktop).
    /// Also sent after the app is activated.
    case focusedWindowChanged(pid: pid_t, window: UInt32?)
    case appLaunched(pid_t)
    /// Sent after `windowDestroyed` for every window of the app that was still tracked. Once per
    /// process, also when macOS posts no termination notification (the process itself is watched).
    case appTerminated(pid_t)
    case appActivated(pid_t)
    case appHidden(pid_t)
    case appUnhidden(pid_t)
    /// Debounced (~750 ms) after screen parameter changes; sorted like ``MonitorInfo/sortedForAeroSpace(_:)``.
    case monitorsChanged([MonitorInfo])
    case activeSpaceChanged
    case willSleep
    case didWake
    case screenLocked
    case screenUnlocked
    /// Global left-mouse-up, top-left global coordinates.
    case leftMouseUp(CGPoint)
}
