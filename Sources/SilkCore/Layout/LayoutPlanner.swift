import CoreGraphics

/// Builds `LayoutPlan`s and remembers what the previous plan showed (for workspace switch detection).
struct LayoutPlanner {
    private var epoch: UInt64 = 0
    private var lastVisibleWorkspaces: [MonitorID: String]?

    /// Lays out every visible workspace and parks the rest. Updates layout bookkeeping on the tree (normalized
    /// weights, last applied rects, hide state).
    mutating func makePlan(_ world: World) -> LayoutPlan {
        epoch += 1
        var layout = TreeLayout(world: world)
        var hidden: [WindowID: HideTarget] = [:]

        if world.isEnabled {
            // Unhide visible workspaces first, then hide the others (AeroSpace order, reduces flicker)
            for monitor in world.monitors {
                let workspace = world.activeWorkspace(on: monitor)
                workspace.allLeafWindowsRecursive.forEach(world.unhideFromCorner)
                layout.layoutWorkspace(workspace)
            }
            let corners = Dictionary(world.monitors.map { ($0.id, world.optimalHideCorner(for: $0)) }, uniquingKeysWith: { first, _ in first })
            for workspace in world.allWorkspaces where !world.isVisible(workspace) {
                let corner = corners[world.monitor(of: workspace).id] ?? .bottomRight
                for window in workspace.allLeafWindowsRecursive where !(window.parent is MacosFullscreenWindowsContainer) {
                    if let target = world.hideTarget(for: window, corner: corner) { hidden[window.id] = target }
                }
            }
        } else {
            // Disabled: every workspace is laid out on its monitor and nothing stays hidden
            for workspace in world.allWorkspaces {
                workspace.allLeafWindowsRecursive.forEach(world.unhideFromCorner)
                layout.layoutWorkspace(workspace)
            }
        }

        let frames = layout.frames
        var newlyPlaced: [WindowID: CGRect] = [:]
        for window in world.windowsById.values {
            guard let initialFrame = window.pendingInitialFrame else { continue }
            if frames[window.id] != nil {
                newlyPlaced[window.id] = initialFrame
                window.pendingInitialFrame = nil
            } else if hidden[window.id] != nil || window.parent is MacosMinimizedWindowsContainer {
                window.pendingInitialFrame = nil
            }
        }

        var userDriven: Set<WindowID> = []
        if let manipulatedId = world.manipulatedWindowId, let workspace = world.window(byId: manipulatedId)?.nodeWorkspace {
            userDriven = Set(workspace.allLeafWindowsRecursive.map(\.id))
        }

        let visible = world.visibleWorkspaceByMonitor.mapValues(\.name)
        var switches: [WorkspaceSwitch] = []
        if let previous = lastVisibleWorkspaces {
            for monitor in world.monitors {
                guard let from = previous[monitor.id], let to = visible[monitor.id], from != to else { continue }
                switches.append(WorkspaceSwitch(monitor: monitor.id, from: from, to: to, direction: world.slideDirection(on: monitor, from: from, to: to)))
            }
        }
        lastVisibleWorkspaces = visible

        return LayoutPlan(
            epoch: epoch,
            frames: frames,
            hidden: hidden,
            newlyPlaced: newlyPlaced,
            userDriven: userDriven,
            workspaceSwitches: switches,
            focusedWindow: world.focus.window?.id
        )
    }
}

extension World {
    /// Slides horizontally if neither side touches another monitor (the next workspace pushes content left),
    /// else through the bottom edge if it's free, else no slide.
    func slideDirection(on monitor: Monitor, from: String, to: String) -> SlideDirection {
        let others = monitors.filter { $0.id != monitor.id }.map(\.frame)
        let frame = monitor.frame
        func overlapsVertically(_ other: CGRect) -> Bool { other.minY < frame.maxY && frame.minY < other.maxY }
        func overlapsHorizontally(_ other: CGRect) -> Bool { other.minX < frame.maxX && frame.minX < other.maxX }
        let leftIsFree = !others.contains { overlapsVertically($0) && $0.maxX <= frame.minX + 1 }
        let rightIsFree = !others.contains { overlapsVertically($0) && $0.minX >= frame.maxX - 1 }
        let bottomIsFree = !others.contains { overlapsHorizontally($0) && $0.minY >= frame.maxY - 1 }
        if leftIsFree && rightIsFree {
            return LogicalSegments(to) < LogicalSegments(from) ? .right : .left
        }
        return bottomIsFree ? .down : .none
    }
}
