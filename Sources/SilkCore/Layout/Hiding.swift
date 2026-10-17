import CoreGraphics

/// Zoom jumps back if a hidden window is left with a 1 pt sliver (AeroSpace issue #527).
let zoomBundleId = "us.zoom.xos"

extension World {
    /// The corner whose surroundings overlap other monitors the least (AeroSpace `monitorToOptimalHideCorner`):
    /// probes just outside each bottom corner and counts monitors containing the probes.
    func optimalHideCorner(for monitor: Monitor) -> HideCorner {
        let frame = monitor.frame
        let xOffset = frame.width * 0.1
        let yOffset = frame.height * 0.1
        let bottomRight = frame.bottomRightCorner
        let bottomLeft = frame.bottomLeftCorner
        let brc1 = bottomRight + CGPoint(x: 2, y: -yOffset)
        let brc2 = bottomRight + CGPoint(x: -xOffset, y: 2)
        let brc3 = bottomRight + CGPoint(x: 2, y: 2)
        let blc1 = bottomLeft + CGPoint(x: -2, y: -yOffset)
        let blc2 = bottomLeft + CGPoint(x: xOffset, y: 2)
        let blc3 = bottomLeft + CGPoint(x: -2, y: 2)
        func contains(_ monitor: Monitor, _ point: CGPoint) -> Int { monitor.frame.containsPoint(point) ? 1 : 0 }
        let important = 10
        let leftScore = monitors.reduce(0) { $0 + contains($1, blc1) + contains($1, blc2) + important * contains($1, blc3) }
        let rightScore = monitors.reduce(0) { $0 + contains($1, brc1) + contains($1, brc2) + important * contains($1, brc3) }
        return leftScore < rightScore ? .bottomLeft : .bottomRight
    }

    /// Parks a window of an invisible workspace (AeroSpace `hideInCorner`). The first time, remembers where it was
    /// as a proportion of its monitor. Nil if the window's frame is unknown.
    func hideTarget(for window: Window, corner: HideCorner) -> HideTarget? {
        guard let workspace = window.nodeWorkspace else { return nil }
        let monitor = monitor(of: workspace)
        if !window.isHiddenInCorner {
            guard let frame = window.lastKnownFrame else { return nil }
            let monitorRect = monitorApproximation(frame.center).frame
            window.prevUnhiddenProportionalPosition = CGPoint(
                x: (frame.minX - monitorRect.minX) / monitorRect.width,
                y: (frame.minY - monitorRect.minY) / monitorRect.height
            )
            if window.isFloating { window.lastFloatingSize = frame.size }
        }
        let visible = monitor.visibleFrame
        let isZoom = window.bundleId == zoomBundleId
        if corner == .bottomLeft, let width = window.lastKnownFrame?.width {
            let onePixelOffset = isZoom ? .zero : CGPoint(x: 1, y: -1)
            let origin = visible.bottomLeftCorner + onePixelOffset + CGPoint(x: -width, y: 0)
            return HideTarget(monitor: monitor.id, monitorVisibleRect: visible, corner: .bottomLeft, origin: origin)
        }
        // Bottom-right doesn't need the window's size
        let onePixelOffset = isZoom ? .zero : CGPoint(x: 1, y: 1)
        return HideTarget(monitor: monitor.id, monitorVisibleRect: visible, corner: .bottomRight, origin: visible.bottomRightCorner - onePixelOffset)
    }

    /// Brings a hidden window back (AeroSpace `unhideFromCorner`): floating windows return to their proportional
    /// position on their workspace's monitor; tiling windows are placed by layout.
    func unhideFromCorner(_ window: Window) {
        guard let proportional = window.prevUnhiddenProportionalPosition else { return }
        guard let workspace = window.nodeWorkspace, window.parent != nil else { return }
        if window.isFloating, let unhidden = unhiddenFloatingFrame(window, workspace: workspace, proportional: proportional) {
            window.lastKnownFrame = unhidden
        }
        window.prevUnhiddenProportionalPosition = nil
    }

    /// Where a hidden floating window will reappear; nil if it isn't hidden.
    func unhiddenFloatingFrame(_ window: Window) -> CGRect? {
        guard let proportional = window.prevUnhiddenProportionalPosition, let workspace = window.nodeWorkspace else { return nil }
        return unhiddenFloatingFrame(window, workspace: workspace, proportional: proportional)
    }

    private func unhiddenFloatingFrame(_ window: Window, workspace: Workspace, proportional: CGPoint) -> CGRect? {
        guard let size = window.lastKnownFrame?.size ?? window.lastFloatingSize else { return nil }
        let rect = monitor(of: workspace).frame
        let floatingWidth = window.lastFloatingSize?.width ?? 0
        let floatingHeight = window.lastFloatingSize?.height ?? 0
        let x = (rect.minX + rect.width * proportional.x).coerced(in: rect.minX ... max(rect.minX, rect.maxX - floatingWidth))
        let y = (rect.minY + rect.height * proportional.y).coerced(in: rect.minY ... max(rect.minY, rect.maxY - floatingHeight))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
