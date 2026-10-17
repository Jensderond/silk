import AppKit
import QuartzCore

/// Appearance of the focus border.
public struct BorderSettings: Equatable {
    /// Stroke width in points, drawn entirely outside the window.
    public var width: CGFloat
    public var color: CGColor
    /// Inner corner radius in points (the window's own radius); nil = calibrated system
    /// radius for the window's chrome (`WindowCornerRadius`).
    public var radius: CGFloat?

    public init(
        width: CGFloat = 2,
        color: CGColor = CGColor(srgbRed: 0x89 / 255, green: 0xB4 / 255, blue: 0xFA / 255, alpha: 1),
        radius: CGFloat? = nil
    ) {
        self.width = width
        self.color = color
        self.radius = radius
    }
}

/// A Hyprland-style border around the focused window: one transparent, click-through panel
/// whose `CAShapeLayer` fills the ring between the window's rounded rect (radius r) and its
/// outset by `width` (radius r + width).
///
/// Ordering: the panel sits at `.normal` level and is placed directly above the target with
/// `order(.above, relativeTo: windowNumber)`, which the window server honours across
/// processes (verified on macOS 26.6 against a TextEdit window, front-to-back window list
/// order checked with `CGWindowListCopyWindowInfo`, both with TextEdit frontmost and behind
/// another app's window: the panel stays immediately above TextEdit and below windows that
/// cover it). The relation is not sticky — when the target or another window is raised the
/// panel keeps its old place — so the Engine calls `reorder()` on focus, activation, raise
/// and Space changes.
///
/// Frames are global top-left-origin points (AX convention). Main thread only.
@MainActor
public final class BorderController {
    public private(set) var settings: BorderSettings
    /// The panel's own window number, so the Engine can ignore it in window tracking.
    public var windowNumber: Int { panel.windowNumber }
    public var isVisible: Bool { target != nil }

    private let panel: NSPanel
    private let ring = CAShapeLayer()
    private var target: (frame: CGRect, windowNumber: Int, chrome: WindowChrome)?
    /// Inner size, radius and width the current path was built for.
    private var pathKey: (size: CGSize, radius: CGFloat, width: CGFloat)?
    /// For AX → Cocoa conversion; refreshed on screen changes (NSScreen.screens is costly per tick).
    private var primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    public init(settings: BorderSettings = BorderSettings()) {
        self.settings = settings
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .normal
        panel.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.becomesKeyOnlyIfNeeded = true

        let root = CALayer()
        let content = NSView(frame: panel.contentLayoutRect)
        content.layer = root
        content.wantsLayer = true
        panel.contentView = content
        ring.fillRule = .evenOdd
        ring.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "fillColor": NSNull()]
        root.addSublayer(ring)
        applyAppearance()

        let names: [(NotificationCenter, Notification.Name)] = [
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
            (DistributedNotificationCenter.default(), Notification.Name("AppleInterfaceThemeChangedNotification")),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification),
        ]
        for (center, name) in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.environmentDidChange() }
            }
            observers.append((center, token))
        }
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
        // Main-thread-only class, so the last release happens on main as well.
        MainActor.assumeIsolated { panel.close() }
    }

    /// Shows the border around `frame` and orders it directly above window `windowNumber`.
    public func show(frame: CGRect, windowNumber: Int, chrome: WindowChrome = .toolbar) {
        target = (frame, windowNumber, chrome)
        layout()
        panel.order(.above, relativeTo: windowNumber)
    }

    /// Follows the target window to `frame`. Cheap enough for every animation tick: an
    /// origin-only change moves the panel; the path is rebuilt only when the size changes.
    public func move(frame: CGRect) {
        guard let current = target, current.frame != frame else { return }
        target?.frame = frame
        layout()
    }

    /// Re-issues the ordering above the target window.
    public func reorder() {
        guard let target else { return }
        panel.order(.above, relativeTo: target.windowNumber)
    }

    public func hide() {
        target = nil
        panel.orderOut(nil)
    }

    public func update(settings: BorderSettings) {
        guard settings != self.settings else { return }
        self.settings = settings
        applyAppearance()
        pathKey = nil
        if target != nil { layout() }
    }

    // MARK: Internals

    private func applyAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.fillColor = settings.color
        CATransaction.commit()
    }

    private func environmentDidChange() {
        primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        WindowCornerRadius.invalidateCache()
        pathKey = nil
        if target != nil { layout() }
    }

    private func layout() {
        guard let target else { return }
        let width = settings.width
        let radius = settings.radius ?? WindowCornerRadius.systemDefault(for: target.chrome)
        let outer = target.frame.insetBy(dx: -width, dy: -width)
        // AX frames are top-left based on the primary screen; Cocoa's are bottom-left.
        let cocoaFrame = NSRect(x: outer.minX, y: primaryScreenHeight - outer.maxY, width: outer.width, height: outer.height)

        // setFrame(_:display:) measured ~3× cheaper than setFrameOrigin on macOS 26.6.
        panel.setFrame(cocoaFrame, display: false)
        if let key = pathKey, key.size == target.frame.size, key.radius == radius, key.width == width { return }
        let bounds = CGRect(origin: .zero, size: outer.size)
        let path = CGMutablePath()
        path.addPath(roundedRect(bounds, radius: radius + width))
        path.addPath(roundedRect(bounds.insetBy(dx: width, dy: width), radius: radius))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.contentsScale = panel.backingScaleFactor
        ring.path = path
        CATransaction.commit()
        pathKey = (target.frame.size, radius, width)
    }

    private func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let radius = max(0, min(radius, rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
