import AppKit

/// The kind of title area a window has; macOS 26 rounds toolbar windows more strongly.
public enum WindowChrome: Equatable, Sendable {
    /// Plain titled window (title bar only).
    case titlebar
    /// Window with a unified toolbar (Finder, Safari, TextEdit, Xcode, …).
    case toolbar
}

/// Calibrates the system's window corner radius, which differs between macOS releases and
/// window styles (macOS 26.6 measured: 16 pt title-bar windows, 26 pt toolbar windows).
///
/// An offscreen titled `NSWindow` of the requested chrome is rendered and its top-left
/// diagonal scanned for the first opaque pixel. Two sources are tried in order:
/// 1. the theme frame (`contentView.superview`) via `cacheDisplay(in:to:)`. On macOS 26 the
///    theme frame draws an unrounded rectangle (the window server applies the corner mask),
///    so this finds no transparency there and calibration moves on;
/// 2. the window's corner-mask image (`_cornerMask`, looked up dynamically and skipped if
///    the selector is missing), the shape the window server actually clips to.
/// If both fail, `fallback` is used. Results are cached and dropped on screen,
/// appearance and accessibility-display changes.
@MainActor
public enum WindowCornerRadius {
    public static let fallback: CGFloat = 16

    private static var cache: [WindowChrome: CGFloat] = [:]
    private static var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Corner radius in points of standard windows with `chrome`.
    public static func systemDefault(for chrome: WindowChrome = .toolbar) -> CGFloat {
        if let cached = cache[chrome] { return cached }
        installInvalidationObservers()
        let radius = measure(chrome) ?? fallback
        cache[chrome] = radius
        return radius
    }

    public static func invalidateCache() {
        cache = [:]
    }

    /// Radius in points of a rounded top-left corner in `bitmap` (row 0 is the top), or nil
    /// when the corner pixel is opaque. The first pixel on the diagonal touched by the shape
    /// gives the arc's distance from the corner to sub-pixel precision: at 45° the arc is
    /// locally a straight edge perpendicular to the diagonal, so the pixel's coverage alpha
    /// determines where inside the pixel the edge lies.
    nonisolated static func cornerRadius(scanning bitmap: NSBitmapImageRep) -> CGFloat? {
        guard bitmap.size.width > 0 else { return nil }
        let scale = Double(bitmap.pixelsWide) / Double(bitmap.size.width)
        let limit = min(bitmap.pixelsWide, bitmap.pixelsHigh) / 2
        for index in 0..<limit {
            let alpha = Double(bitmap.colorAt(x: index, y: index)?.alphaComponent ?? 0)
            guard alpha > 0.01 else { continue }
            if index == 0 && alpha > 0.99 { return nil }
            // Coverage of pixel [i, i+1]² by the half-plane x + y ≥ c, solved for c − 2i.
            let offset = alpha >= 0.5 ? (2 * (1 - alpha)).squareRoot() : 2 - (2 * alpha).squareRoot()
            let perAxisPixels = Double(index) + offset / 2
            let radius = perAxisPixels / scale / (1 - 1 / 2.0.squareRoot())
            return CGFloat((radius * 2).rounded() / 2)
        }
        return nil
    }

    private static func measure(_ chrome: WindowChrome) -> CGFloat? {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        if chrome == .toolbar {
            window.toolbar = NSToolbar(identifier: "silk.corner-calibration")
            window.toolbarStyle = .unified
        }
        defer { window.close() }

        if let themeFrame = window.contentView?.superview,
           let bitmap = themeFrame.bitmapImageRepForCachingDisplay(in: themeFrame.bounds)
        {
            themeFrame.cacheDisplay(in: themeFrame.bounds, to: bitmap)
            if let radius = cornerRadius(scanning: bitmap) { return radius }
        }

        let cornerMask = NSSelectorFromString("_cornerMask")
        guard window.responds(to: cornerMask),
              let image = window.perform(cornerMask)?.takeUnretainedValue() as? NSImage,
              image.size.width > 0, image.size.height > 0,
              let bitmap = render(image, scale: 4)
        else { return nil }
        return cornerRadius(scanning: bitmap)
    }

    private static func render(_ image: NSImage, scale: Int) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(image.size.width.rounded(.up)) * scale,
            pixelsHigh: Int(image.size.height.rounded(.up)) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = NSSize(width: image.size.width.rounded(.up), height: image.size.height.rounded(.up))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: bitmap.size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private static func installInvalidationObservers() {
        guard observers.isEmpty else { return }
        let names: [(NotificationCenter, Notification.Name)] = [
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
            (DistributedNotificationCenter.default(), Notification.Name("AppleInterfaceThemeChangedNotification")),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification),
        ]
        for (center, name) in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { invalidateCache() }
            }
            observers.append((center, token))
        }
    }
}
