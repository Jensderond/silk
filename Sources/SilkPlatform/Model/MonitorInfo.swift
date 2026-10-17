import AppKit
import CoreGraphics

/// A display, in global top-left-origin coordinates.
public struct MonitorInfo: Sendable, Equatable {
    /// Display UUID (`CGDisplayCreateUUIDFromDisplayID`); stable across reconnects.
    public var id: String
    public var displayID: CGDirectDisplayID
    /// `NSScreen.localizedName`, e.g. "Built-in Retina Display".
    public var name: String
    public var frame: CGRect
    /// Frame minus menu bar and Dock.
    public var visibleFrame: CGRect
    /// The primary display (origin at 0,0; carries the menu bar).
    public var isMain: Bool
    /// Maximum refresh rate in Hz (120 on ProMotion).
    public var refreshRate: Double

    public init(id: String, displayID: CGDirectDisplayID, name: String, frame: CGRect, visibleFrame: CGRect, isMain: Bool, refreshRate: Double) {
        self.id = id
        self.displayID = displayID
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isMain = isMain
        self.refreshRate = refreshRate
    }

    /// AeroSpace's monitor order (`sortedMonitorInfos`): left to right, then top to bottom.
    public static func sortedForAeroSpace(_ monitors: [MonitorInfo]) -> [MonitorInfo] {
        monitors.sorted { lhs, rhs in
            lhs.frame.minX != rhs.frame.minX ? lhs.frame.minX < rhs.frame.minX : lhs.frame.minY < rhs.frame.minY
        }
    }

    /// Reads the current displays from `NSScreen.screens`. Main thread only.
    public static func current() -> [MonitorInfo] {
        let screens = NSScreen.screens
        guard let primaryHeight = ScreenGeometry.primaryScreenHeight(screens) else { return [] }
        let monitors = screens.compactMap { screen -> MonitorInfo? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            return MonitorInfo(
                id: displayUUID(displayID) ?? "display-\(displayID)",
                displayID: displayID,
                name: screen.localizedName,
                frame: ScreenGeometry.topLeftRect(fromAppKit: screen.frame, primaryScreenHeight: primaryHeight),
                visibleFrame: ScreenGeometry.topLeftRect(fromAppKit: screen.visibleFrame, primaryScreenHeight: primaryHeight),
                isMain: screen.frame.origin == .zero,
                refreshRate: refreshRate(of: screen, displayID: displayID)
            )
        }
        return sortedForAeroSpace(monitors)
    }

    private static func displayUUID(_ displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    private static func refreshRate(of screen: NSScreen, displayID: CGDirectDisplayID) -> Double {
        let maximum = Double(screen.maximumFramesPerSecond)
        if maximum > 0 { return maximum }
        let modeRate = CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0
        return modeRate > 0 ? modeRate : 60
    }
}

/// Conversions between AppKit's bottom-left-origin screen space and the global
/// top-left-origin space used by AX, CoreGraphics and the rest of Silk.
public enum ScreenGeometry {
    /// Converts an AppKit rect (origin bottom-left of the primary screen, y up) to top-left global coordinates.
    public static func topLeftRect(fromAppKit rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Converts an AppKit point (e.g. `NSEvent.mouseLocation`) to top-left global coordinates.
    public static func topLeftPoint(fromAppKit point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// Height of the primary screen (the one at the AppKit origin), falling back to the first screen.
    static func primaryScreenHeight(_ screens: [NSScreen]) -> CGFloat? {
        (screens.first { $0.frame.origin == .zero } ?? screens.first)?.frame.height
    }
}
