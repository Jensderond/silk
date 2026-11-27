import AppKit
import CoreImage
import SilkCore
import SilkPlatform

/// The bars standing in for windows collapsed with `minimize-to-bar`: small always-on-top panels stacked upwards
/// from the bottom-right corner of the monitor, one per window, showing the app's icon and the window's title.
/// Clicking one brings its window back.
@MainActor
final class CollapsedBars {
    static let height: CGFloat = 30
    static let width: CGFloat = 220
    static let margin: CGFloat = 8
    static let gap: CGFloat = 6
    /// How much a bar grows under the mouse, away from the screen corner.
    static let hoverGrowth = CGSize(width: 16, height: 4)
    static let hoverDuration: TimeInterval = 0.14

    /// Called with the window whose bar was clicked.
    var onClick: ((UInt32) -> Void)?
    private var panels: [UInt32: NSPanel] = [:]
    /// Each bar's resting frame (AppKit coordinates).
    private var restingFrames: [UInt32: NSRect] = [:]
    private var hovered: UInt32?

    /// Where each bar goes, in global top-left coordinates. Per monitor the first (oldest) bar is the lowest.
    static func frames(for bars: [CollapsedBar]) -> [UInt32: CGRect] {
        var result: [UInt32: CGRect] = [:]
        var countByMonitor: [MonitorID: Int] = [:]
        for bar in bars {
            let index = countByMonitor[bar.monitor, default: 0]
            countByMonitor[bar.monitor] = index + 1
            let visible = bar.monitorVisibleRect
            result[bar.window] = CGRect(
                x: visible.maxX - margin - width,
                y: visible.maxY - margin - height - CGFloat(index) * (height + gap),
                width: width,
                height: height
            )
        }
        return result
    }

    /// Shows exactly these bars.
    func update(_ bars: [CollapsedBar]) {
        let frames = Self.frames(for: bars)
        for (id, panel) in panels where frames[id] == nil {
            panel.orderOut(nil)
            panels[id] = nil
            restingFrames[id] = nil
            if hovered == id { hovered = nil }
        }
        for bar in bars {
            guard let frame = frames[bar.window], let appKitFrame = ScreenGeometry.appKitRect(fromTopLeft: frame) else { continue }
            let panel = panels[bar.window] ?? makePanel(for: bar.window)
            panels[bar.window] = panel
            (panel.contentView as? BarView)?.set(bar)
            restingFrames[bar.window] = appKitFrame
            let target = currentFrame(of: bar.window) ?? appKitFrame
            if panel.frame != target { panel.setFrame(target, display: true) }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    func close() {
        update([])
    }

    /// The bar's frame now: its resting frame, grown up and to the left while the mouse is over it.
    private func currentFrame(of window: UInt32) -> NSRect? {
        guard let resting = restingFrames[window] else { return nil }
        guard hovered == window else { return resting }
        return NSRect(
            x: resting.minX - Self.hoverGrowth.width, y: resting.minY,
            width: resting.width + Self.hoverGrowth.width, height: resting.height + Self.hoverGrowth.height
        )
    }

    private func setHovered(_ isHovered: Bool, window: UInt32) {
        let previous = hovered
        if isHovered { hovered = window } else if hovered == window { hovered = nil }
        guard hovered != previous else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : Self.hoverDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.165, 0.84, 0.44, 1)
            context.allowsImplicitAnimation = true
            for id in Set([previous, hovered].compactMap { $0 }) {
                guard let panel = panels[id], let target = currentFrame(of: id) else { continue }
                panel.animator().setFrame(target, display: true)
            }
        }
    }

    private func makePanel(for window: UInt32) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        let view = BarView { [weak self] in self?.onClick?(window) }
        view.onHover = { [weak self] isHovered in self?.setHovered(isHovered, window: window) }
        panel.contentView = view
        return panel
    }
}

/// One bar: icon, title, and the whole surface is the button.
private final class BarView: NSView {
    private let background = NSVisualEffectView()
    /// The app's icon, enlarged, blurred and darkened: a faint wash of the app's colours over the dark bar.
    private let tint = NSView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let action: () -> Void
    var onHover: ((Bool) -> Void)?
    private var pid: pid_t?
    private var isPressed = false { didSet { background.alphaValue = isPressed ? 0.7 : 1 } }

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        background.autoresizingMask = [.width, .height]
        addSubview(background)
        tint.wantsLayer = true
        tint.layer?.contentsGravity = .resizeAspectFill
        tint.layer?.masksToBounds = true
        tint.layer?.backgroundColor = NSColor(white: 0.09, alpha: 0.92).cgColor
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        tint.autoresizingMask = [.width, .height]
        background.addSubview(tint)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        setAccessibilityRole(.button)
        // Added once: `.inVisibleRect` follows the bar as it grows. Recreating the area while the mouse is
        // inside would make it miss the exit.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(_ bar: CollapsedBar) {
        if pid != bar.pid {
            pid = bar.pid
            let image = NSRunningApplication(processIdentifier: bar.pid)?.icon
            icon.image = image
            tint.layer?.contents = image.flatMap(BarView.wash)
        }
        let title = bar.title.isEmpty ? (bar.appName ?? "Window") : bar.title
        label.stringValue = title
        toolTip = [bar.appName, bar.title.isEmpty ? nil : bar.title].compactMap { $0 }.joined(separator: " — ")
        setAccessibilityLabel("Restore \(title)")
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        tint.frame = background.bounds
        // Grows with the bar (hover)
        let iconSize: CGFloat = (bounds.height * 0.6).rounded()
        icon.frame = NSRect(x: 8, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let labelHeight = ceil(label.intrinsicContentSize.height)
        let labelX = icon.frame.maxX + 7
        label.frame = NSRect(x: labelX, y: (bounds.height - labelHeight) / 2, width: max(0, bounds.width - labelX - 10), height: labelHeight)
    }

    /// The icon blown up, blurred until only its colours are left, and darkened so white text stays readable.
    static func wash(of image: NSImage) -> CGImage? {
        var rect = NSRect(x: 0, y: 0, width: 128, height: 128)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: source)
        let extent = input.extent
        // Over near-black: transparent corners of the icon must not turn into bright haze
        let backdrop = CIImage(color: CIColor(red: 0.09, green: 0.09, blue: 0.09)).cropped(to: extent)
        let washed = input.composited(over: backdrop)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(extent.width) * 0.16)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.25, kCIInputBrightnessKey: -0.06])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.24, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.24, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.24, w: 0),
            ])
            // The middle of the icon, so the bar shows it enlarged
            .cropped(to: extent.insetBy(dx: extent.width * 0.2, dy: extent.height * 0.2))
        return CIContext().createCGImage(washed, from: washed.extent)
    }

    // The panel never becomes key, so the first click has to count
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { isPressed = true }
    override func mouseDragged(with event: NSEvent) { isPressed = bounds.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { action() }
    }
    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
