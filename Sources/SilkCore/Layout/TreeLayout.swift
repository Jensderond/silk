import CoreGraphics

/// One layout pass: AeroSpace `layoutRecursive`, recording target frames instead of writing them.
/// Records `lastAppliedLayout*Rect` on every node and normalizes tile weights to the available size.
struct TreeLayout {
    private struct Context {
        let workspace: Workspace
        let monitor: Monitor
        let gaps: ResolvedGaps
    }

    let world: World
    private(set) var frames: [WindowID: CGRect] = [:]

    init(world: World) { self.world = world }

    mutating func layoutWorkspace(_ workspace: Workspace) {
        if workspace.isEffectivelyEmpty { return }
        let monitor = world.monitor(of: workspace)
        let rect = world.visibleRectPaddedByOuterGaps(monitor)
        let context = Context(workspace: workspace, monitor: monitor, gaps: world.resolvedGaps(monitor))
        // If monitors are stacked vertically and the lower one is narrower, macOS may refuse full width to windows of
        // the upper one; one point less of height avoids it (AeroSpace hack, seen in horizontal setups too).
        layoutRecursive(workspace, rect.topLeftCorner, width: rect.width, height: rect.height - 1, virtual: rect, context)
    }

    private mutating func layoutRecursive(_ node: TreeNode, _ point: CGPoint, width: CGFloat, height: CGFloat, virtual: CGRect, _ context: Context) {
        let physicalRect = CGRect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        switch node {
            case let workspace as Workspace:
                workspace.lastAppliedLayoutPhysicalRect = physicalRect
                workspace.lastAppliedLayoutVirtualRect = virtual
                layoutRecursive(workspace.rootTilingContainer, point, width: width, height: height, virtual: virtual, context)
                // Don't create a floating container here: a new empty container would become the workspace's most
                // recent child and hide the most recent window from focus resolution.
                if let floating = workspace.children.first(where: { $0 is FloatingWindowsContainer }) {
                    layoutRecursive(floating, point, width: width, height: height, virtual: virtual, context)
                }
            case let container as FloatingWindowsContainer:
                for case let window as Window in container.children {
                    window.lastAppliedLayoutPhysicalRect = nil
                    window.lastAppliedLayoutVirtualRect = nil
                    layoutFloatingWindow(window, context)
                }
            case let window as Window:
                guard window.id != world.manipulatedWindowId else { return }
                window.lastAppliedLayoutVirtualRect = virtual
                if window.isFullscreen && window === context.workspace.rootTilingContainer.mostRecentWindowRecursive {
                    window.lastAppliedLayoutPhysicalRect = nil
                    frames[window.id] = fullscreenRect(window, context)
                } else {
                    window.lastAppliedLayoutPhysicalRect = physicalRect
                    window.isFullscreen = false
                    frames[window.id] = physicalRect
                }
            case let container as TilingContainer:
                container.lastAppliedLayoutPhysicalRect = physicalRect
                container.lastAppliedLayoutVirtualRect = virtual
                switch container.layout {
                    case .tiles: layoutTiles(container, point, width: width, height: height, virtual: virtual, context)
                    case .accordion: layoutAccordion(container, point, width: width, height: height, virtual: virtual, context)
                }
            default:
                return // macOS special containers aren't laid out
        }
    }

    private mutating func layoutTiles(_ container: TilingContainer, _ point: CGPoint, width: CGFloat, height: CGFloat, virtual: CGRect, _ context: Context) {
        let orientation = container.orientation
        let children = container.children
        let weightsSum = children.reduce(0) { $0 + $1.getWeight(orientation) }
        guard let delta = ((orientation == .h ? width : height) - weightsSum).divided(by: children.count) else { return }
        var point = point
        var virtualPoint = virtual.topLeftCorner
        let rawGap = CGFloat(context.gaps.inner(orientation))
        for (index, child) in children.enumerated() {
            child.setWeight(orientation, child.getWeight(orientation) + delta)
            // The first and last children only have a gap on their inner side
            let gap = rawGap - (index == 0 ? rawGap / 2 : 0) - (index == children.count - 1 ? rawGap / 2 : 0)
            let weight = child.getWeight(orientation)
            layoutRecursive(
                child,
                index == 0 ? point : point.addingOffset(orientation, rawGap / 2),
                width: orientation == .h ? weight - gap : width,
                height: orientation == .v ? weight - gap : height,
                virtual: CGRect(
                    topLeftX: virtualPoint.x,
                    topLeftY: virtualPoint.y,
                    width: orientation == .h ? weight : width,
                    height: orientation == .v ? weight : height
                ),
                context
            )
            virtualPoint = virtualPoint.addingOffset(orientation, weight)
            point = point.addingOffset(orientation, weight)
        }
    }

    private mutating func layoutAccordion(_ container: TilingContainer, _ point: CGPoint, width: CGFloat, height: CGFloat, virtual: CGRect, _ context: Context) {
        guard let mruIndex = container.mostRecentChild?.ownIndex else { return }
        let padding = CGFloat(world.config.accordionPadding)
        let children = container.children
        for (index, child) in children.enumerated() {
            let (leadingPadding, trailingPadding): (CGFloat, CGFloat) = switch index {
                case 0 where children.count == 1: (0, 0)
                case 0: (0, padding)
                case children.count - 1: (padding, 0)
                case mruIndex - 1: (0, 2 * padding)
                case mruIndex + 1: (2 * padding, 0)
                default: (padding, padding)
            }
            switch container.orientation {
                case .h:
                    layoutRecursive(child, point + CGPoint(x: leadingPadding, y: 0), width: width - trailingPadding - leadingPadding, height: height, virtual: virtual, context)
                case .v:
                    layoutRecursive(child, point + CGPoint(x: 0, y: leadingPadding), width: width, height: height - leadingPadding - trailingPadding, virtual: virtual, context)
            }
        }
    }

    /// Floating windows keep their frame, unless they're on another monitor than their workspace (it moved):
    /// then they move proportionally into the workspace's monitor (AeroSpace `layoutFloatingWindow`).
    private mutating func layoutFloatingWindow(_ window: Window, _ context: Context) {
        guard var frame = window.lastKnownFrame else { return }
        guard window.id != world.manipulatedWindowId else { return }
        let currentMonitor = world.monitorApproximation(frame.center)
        if context.workspace !== world.activeWorkspace(on: currentMonitor) {
            let from = currentMonitor.visibleFrame
            let to = context.monitor.visibleFrame
            let xProportion = (frame.minX - from.minX) / from.width
            let yProportion = (frame.minY - from.minY) / from.height
            frame.origin = CGPoint(
                x: (to.minX + xProportion * to.width).coerced(in: to.minX ... max(to.minX, to.maxX - frame.width)),
                y: (to.minY + yProportion * to.height).coerced(in: to.minY ... max(to.minY, to.maxY - frame.height))
            )
        }
        if window.isFullscreen {
            frame = fullscreenRect(window, context)
            window.isFullscreen = false
        }
        window.lastKnownFrame = frame
        frames[window.id] = frame
    }

    private func fullscreenRect(_ window: Window, _ context: Context) -> CGRect {
        window.noOuterGapsInFullscreen ? context.monitor.visibleFrame : world.visibleRectPaddedByOuterGaps(context.monitor)
    }
}
