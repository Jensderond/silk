import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Mouse and keyboard state queries. Thread-safe.
public enum InputState {
    /// Whether the left mouse button is currently pressed.
    public static var isLeftMouseDown: Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    /// Mouse location in global top-left-origin coordinates.
    public static var mouseLocation: CGPoint {
        if let location = CGEvent(source: nil)?.location { return location }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return ScreenGeometry.topLeftPoint(fromAppKit: NSEvent.mouseLocation, primaryScreenHeight: primaryHeight)
    }

    /// Secure keyboard entry (password fields, some terminals) is on: Carbon hotkeys don't fire.
    public static var isSecureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }

    /// Warps the cursor to `point` (global top-left coordinates) without the post-warp input freeze.
    public static func moveMouse(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
