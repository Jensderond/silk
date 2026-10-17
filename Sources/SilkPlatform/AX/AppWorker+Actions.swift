import AppKit
import ApplicationServices
import SilkPrivateAPI

/// How ``PlatformService/focus(window:pid:)`` brings a window to the front.
public enum FocusBackend: String, Sendable {
    /// AeroSpace's path: `AXMain = true`, `AXRaise`, then activate the app.
    case appKit
    /// yabai's SkyLight path (`_SLPSSetFrontProcessWithOptions` + make-key-window event records +
    /// `AXRaise`), verified by the focused-window notification within 100 ms, else falls back to ``appKit``.
    case skylight
}

/// Window actions. Worker thread only.
extension AppWorker {
    static let skylightVerificationTimeout: TimeInterval = 0.1

    /// - Parameter allowShortcut: AeroSpace's optimisation (skip AX when the window is already the
    ///   app's focused window or the app has one window). The caller passes false when displays have
    ///   separate Spaces and there is more than one monitor (macOS bug, AeroSpace #101).
    func focus(_ id: UInt32, backend: FocusBackend, allowShortcut: Bool) {
        if allowShortcut && (focusedWindowID == id || windows.count == 1) {
            activateApp()
            return
        }
        guard let window = windows[id] else { return }
        switch backend {
            case .appKit:
                focusWithAppKit(window)
            case .skylight:
                guard silk_skylight_focus_window(pid, id) else { return focusWithAppKit(window) }
                window.element.perform(kAXRaiseAction)
                startFocusVerification(id)
        }
    }

    private func focusWithAppKit(_ window: TrackedWindow) {
        // Raise first so the window is already on top when the app activates.
        window.element.set(kAXMainAttribute, kCFBooleanTrue)
        window.element.perform(kAXRaiseAction)
        activateApp()
    }

    private func activateApp() {
        Self.activate(app)
    }

    /// AeroSpace's `activate(options: .activateIgnoringOtherApps)`; the option is a no-op since macOS 14.
    static func activate(_ app: NSRunningApplication) {
        app.activate(options: [])
    }

    private func startFocusVerification(_ id: UInt32) {
        if let previous = pendingFocusVerification { CFRunLoopTimerInvalidate(previous.timer) }
        let timer = schedule(after: Self.skylightVerificationTimeout) { [self] in
            guard let pending = pendingFocusVerification, pending.window == id else { return }
            pendingFocusVerification = nil
            let focused = appElement.element(kAXFocusedWindowAttribute)?.windowID
            if focused != id || !app.isActive, let window = windows[id] {
                platformLog.debug("SkyLight focus of \(id) unconfirmed; falling back to AppKit")
                focusWithAppKit(window)
            }
        }
        pendingFocusVerification = (id, timer)
    }

    func confirmFocusVerification(_ focused: UInt32) {
        guard let pending = pendingFocusVerification, pending.window == focused else { return }
        CFRunLoopTimerInvalidate(pending.timer)
        pendingFocusVerification = nil
    }

    func raise(_ id: UInt32) {
        windows[id]?.element.perform(kAXRaiseAction)
    }

    /// Presses the close button. Returns whether it was pressed; destruction is reported by
    /// `windowDestroyed` (the app may also show a "save changes?" sheet instead).
    func close(_ id: UInt32) -> Bool {
        guard let button = windows[id]?.element.element(kAXCloseButtonAttribute) else { return false }
        return button.perform(kAXPressAction) == .success
    }

    func setMinimized(_ id: UInt32, _ value: Bool) {
        windows[id]?.element.set(kAXMinimizedAttribute, value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    func setFullscreen(_ id: UInt32, _ value: Bool) {
        windows[id]?.element.set(AXAttribute.fullScreen, value ? kCFBooleanTrue : kCFBooleanFalse)
    }
}
