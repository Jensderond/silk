import CoreGraphics

/// A monitor's top-left corner. AeroSpace identifies monitors by it rather than by display id: visible workspaces,
/// the previously visible ones and invisible workspaces' last monitors are all keyed by screen position, so after a
/// display rearrangement (e.g. docking makes the external display the main one at the origin) workspaces follow
/// screen positions, not physical displays.
struct ScreenPoint: Hashable, Comparable {
    let x: CGFloat
    let y: CGFloat

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }

    static func < (lhs: ScreenPoint, rhs: ScreenPoint) -> Bool { (lhs.x, lhs.y) < (rhs.x, rhs.y) }
}

extension Monitor {
    var screenPoint: ScreenPoint { ScreenPoint(frame.topLeftCorner) }
}

extension World {
    /// Gets or creates the workspace. Created workspaces live until garbage collected.
    func workspace(named name: String) -> Workspace {
        if let existing = workspacesByName[name] { return existing }
        let workspace = Workspace(name: name, world: self)
        workspacesByName[name] = workspace
        return workspace
    }

    var allWorkspaces: [Workspace] { workspacesByName.values.sorted() }

    func isVisible(_ workspace: Workspace) -> Bool { visibleWorkspaceToScreenPoint[workspace.name] != nil }

    /// The workspace shown on each connected monitor.
    var visibleWorkspaceByMonitor: [MonitorID: Workspace] {
        var result: [MonitorID: Workspace] = [:]
        for monitor in monitors {
            if let workspace = screenPointToVisibleWorkspace[monitor.screenPoint] { result[monitor.id] = workspace }
        }
        return result
    }

    /// Persistent workspaces always exist; others die once empty, invisible and unfocused.
    func garbageCollectUnusedWorkspaces() {
        let persistent = Set(config.persistentWorkspaces)
        for name in config.persistentWorkspaces { _ = workspace(named: name) }
        let focusedName = focus.workspace.name
        workspacesByName = workspacesByName.filter { name, workspace in
            persistent.contains(name) || !workspace.isEffectivelyEmpty || isVisible(workspace) || name == focusedName
        }
    }

    /// The monitor a workspace is shown on (AeroSpace `workspaceMonitor`): its force-assigned monitor, else the one
    /// at the screen position where it's visible, else the one closest to where it was last shown, else the main one.
    func monitor(of workspace: Workspace) -> Monitor {
        if let forced = forceAssignedMonitor(of: workspace) { return forced }
        if let point = visibleWorkspaceToScreenPoint[workspace.name] { return monitorApproximation(point.cgPoint) }
        if let point = workspace.assignedMonitorPoint { return monitorApproximation(point.cgPoint) }
        return mainMonitor
    }

    /// The first connected monitor of `workspace-to-monitor-force-assignment`.
    func forceAssignedMonitor(of workspace: Workspace) -> Monitor? {
        guard let patterns = config.workspaceToMonitorForceAssignment[workspace.name] else { return nil }
        let sorted = sortedMonitors
        return patterns.lazy.compactMap { self.resolve($0, sortedMonitors: sorted) }.first
    }

    func activeWorkspace(on monitor: Monitor) -> Workspace {
        if let existing = screenPointToVisibleWorkspace[monitor.screenPoint] { return existing }
        // The monitor configuration changed (a top-left corner moved)
        rearrangeWorkspacesOnMonitors()
        return screenPointToVisibleWorkspace[monitor.screenPoint] ?? stubWorkspace(for: monitor)
    }

    /// Shows `workspace` on `monitor`. Fails if the workspace is force-assigned to another monitor.
    @discardableResult
    func setActiveWorkspace(_ workspace: Workspace, on monitor: Monitor) -> Bool {
        setActiveWorkspace(workspace, at: monitor.screenPoint)
    }

    private func setActiveWorkspace(_ workspace: Workspace, at point: ScreenPoint) -> Bool {
        if let forced = forceAssignedMonitor(of: workspace), forced.screenPoint != point { return false }
        if let previousPoint = visibleWorkspaceToScreenPoint.removeValue(forKey: workspace.name) {
            screenPointToPrevVisibleWorkspace[previousPoint] = screenPointToVisibleWorkspace.removeValue(forKey: previousPoint)?.name
        }
        if let previous = screenPointToVisibleWorkspace.removeValue(forKey: point) {
            screenPointToPrevVisibleWorkspace[point] = previous.name
            visibleWorkspaceToScreenPoint.removeValue(forKey: previous.name)
        }
        visibleWorkspaceToScreenPoint[workspace.name] = point
        screenPointToVisibleWorkspace[point] = workspace
        workspace.assignedMonitorPoint = point
        return true
    }

    /// An invisible workspace that belongs to `monitor`, to show when the monitor's workspace leaves it.
    func stubWorkspace(for monitor: Monitor) -> Workspace {
        stubWorkspace(at: monitor.screenPoint)
    }

    private func stubWorkspace(at point: ScreenPoint) -> Workspace {
        // AeroSpace looks the previous workspace up by name, recreating it if it was garbage collected
        if let previousName = screenPointToPrevVisibleWorkspace[point] {
            let previous = workspace(named: previousName)
            if !isVisible(previous) && monitor(of: previous).screenPoint == point && forceAssignedMonitor(of: previous) == nil {
                return previous
            }
        }
        if let candidate = allWorkspaces.first(where: { !isVisible($0) && monitor(of: $0).screenPoint == point }) {
            return candidate
        }
        let persistent = Set(config.persistentWorkspaces)
        var number = 1
        while true {
            let candidate = workspace(named: String(number))
            if candidate.isEffectivelyEmpty && !isVisible(candidate) && !persistent.contains(candidate.name)
                && forceAssignedMonitor(of: candidate) == nil
            {
                return candidate
            }
            number += 1
        }
    }

    /// AeroSpace `gcMonitors`: re-establishes "every monitor shows exactly one workspace" when the number of monitors
    /// changed or a monitor's top-left corner isn't known.
    func gcMonitors() {
        if screenPointToVisibleWorkspace.count != monitors.count
            || monitors.contains(where: { screenPointToVisibleWorkspace[$0.screenPoint] == nil })
        {
            rearrangeWorkspacesOnMonitors()
        }
    }

    /// AeroSpace `rearrangeWorkspacesOnMonitors`: every previously visible workspace goes to the new monitor whose
    /// top-left corner is closest to its old one (ties and conflicts go to the closest old monitor); other monitors
    /// get a stub workspace.
    func rearrangeWorkspacesOnMonitors() {
        let newScreens = monitors.map(\.screenPoint)
        var newScreenToOldScreen: [ScreenPoint: ScreenPoint] = [:]
        for oldScreen in screenPointToVisibleWorkspace.keys.sorted() {
            func distance(_ newScreen: ScreenPoint) -> CGFloat { (newScreen.cgPoint - oldScreen.cgPoint).vectorLength }
            guard let newScreen = newScreens.min(by: { distance($0) < distance($1) }) else { continue }
            if let previousOldScreen = newScreenToOldScreen[newScreen],
               (previousOldScreen.cgPoint - newScreen.cgPoint).vectorLength <= distance(newScreen)
            {
                continue // newScreen has already been assigned to a closer old screen
            }
            newScreenToOldScreen[newScreen] = oldScreen
        }

        let oldScreenToVisibleWorkspace = screenPointToVisibleWorkspace
        screenPointToVisibleWorkspace = [:]
        visibleWorkspaceToScreenPoint = [:]

        for newScreen in newScreens {
            if let existing = newScreenToOldScreen[newScreen].flatMap({ oldScreenToVisibleWorkspace[$0] }),
               setActiveWorkspace(existing, at: newScreen)
            {
                continue
            }
            let stub = stubWorkspace(at: newScreen)
            _ = setActiveWorkspace(stub, at: newScreen)
        }
    }
}
