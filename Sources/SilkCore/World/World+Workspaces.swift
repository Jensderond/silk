import CoreGraphics

extension World {
    /// Gets or creates the workspace. Created workspaces live until garbage collected.
    func workspace(named name: String) -> Workspace {
        if let existing = workspacesByName[name] { return existing }
        let workspace = Workspace(name: name, world: self)
        workspacesByName[name] = workspace
        return workspace
    }

    var allWorkspaces: [Workspace] { workspacesByName.values.sorted() }

    func isVisible(_ workspace: Workspace) -> Bool { monitorOfVisibleWorkspace[workspace.name] != nil }

    /// Persistent workspaces always exist; others die once empty, invisible and unfocused.
    func garbageCollectUnusedWorkspaces() {
        let persistent = Set(config.persistentWorkspaces)
        for name in config.persistentWorkspaces { _ = workspace(named: name) }
        let focusedName = focus.workspace.name
        workspacesByName = workspacesByName.filter { name, workspace in
            persistent.contains(name) || !workspace.isEffectivelyEmpty || isVisible(workspace) || name == focusedName
        }
    }

    /// The monitor a workspace is shown on: its force-assigned monitor, else where it's visible, else the monitor
    /// it was last shown on, else the main monitor.
    func monitor(of workspace: Workspace) -> Monitor {
        if let forced = forceAssignedMonitor(of: workspace) { return forced }
        if let id = monitorOfVisibleWorkspace[workspace.name], let monitor = monitor(id: id) { return monitor }
        if let id = workspace.assignedMonitorId {
            if let monitor = monitor(id: id) { return monitor }
            if let frame = lastKnownMonitorFrames[id] { return monitorApproximation(frame.topLeftCorner) }
        }
        return mainMonitor
    }

    /// The first connected monitor of `workspace-to-monitor-force-assignment`.
    func forceAssignedMonitor(of workspace: Workspace) -> Monitor? {
        guard let patterns = config.workspaceToMonitorForceAssignment[workspace.name] else { return nil }
        let sorted = sortedMonitors
        return patterns.lazy.compactMap { self.resolve($0, sortedMonitors: sorted) }.first
    }

    func activeWorkspace(on monitor: Monitor) -> Workspace {
        if let existing = visibleWorkspaceByMonitor[monitor.id] { return existing }
        rearrangeWorkspacesOnMonitors(previousMonitors: monitors)
        return visibleWorkspaceByMonitor[monitor.id] ?? stubWorkspace(for: monitor)
    }

    /// Shows `workspace` on `monitor`. Fails if the workspace is force-assigned to another monitor.
    @discardableResult
    func setActiveWorkspace(_ workspace: Workspace, on monitor: Monitor) -> Bool {
        if let forced = forceAssignedMonitor(of: workspace), forced.id != monitor.id { return false }
        if let previousMonitorId = monitorOfVisibleWorkspace.removeValue(forKey: workspace.name) {
            if let previous = visibleWorkspaceByMonitor.removeValue(forKey: previousMonitorId) {
                prevVisibleWorkspaceByMonitor[previousMonitorId] = previous.name
            }
        }
        if let previous = visibleWorkspaceByMonitor.removeValue(forKey: monitor.id) {
            prevVisibleWorkspaceByMonitor[monitor.id] = previous.name
            monitorOfVisibleWorkspace.removeValue(forKey: previous.name)
        }
        visibleWorkspaceByMonitor[monitor.id] = workspace
        monitorOfVisibleWorkspace[workspace.name] = monitor.id
        workspace.assignedMonitorId = monitor.id
        return true
    }

    /// An invisible workspace that belongs to `monitor`, to show when the monitor's workspace leaves it.
    func stubWorkspace(for monitor: Monitor) -> Workspace {
        let persistent = Set(config.persistentWorkspaces)
        if let previousName = prevVisibleWorkspaceByMonitor[monitor.id], let previous = workspacesByName[previousName],
           !isVisible(previous), self.monitor(of: previous).id == monitor.id, forceAssignedMonitor(of: previous) == nil
        {
            return previous
        }
        if let candidate = allWorkspaces.first(where: { !isVisible($0) && self.monitor(of: $0).id == monitor.id }) {
            return candidate
        }
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

    /// Re-establishes "every monitor shows exactly one workspace" after a monitor change. Visible workspaces stay on
    /// their monitor (matched by id, else by the closest previous top-left corner); other monitors get a stub.
    func rearrangeWorkspacesOnMonitors(previousMonitors: [Monitor]) {
        let oldVisible = visibleWorkspaceByMonitor
        let previousFrames = Dictionary(previousMonitors.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        func previousTopLeft(_ id: MonitorID) -> CGPoint? { (previousFrames[id] ?? lastKnownMonitorFrames[id])?.topLeftCorner }

        var newToOld: [MonitorID: MonitorID] = [:]
        for monitor in monitors where oldVisible[monitor.id] != nil {
            newToOld[monitor.id] = monitor.id
        }
        let presentIds = Set(monitors.map(\.id))
        let unmatchedMonitors = monitors.filter { newToOld[$0.id] == nil }
        for oldId in oldVisible.keys.sorted() where !presentIds.contains(oldId) {
            guard let oldPoint = previousTopLeft(oldId) else { continue }
            func distance(_ monitor: Monitor) -> CGFloat { (monitor.frame.topLeftCorner - oldPoint).vectorLength }
            guard let closest = unmatchedMonitors.min(by: { distance($0) < distance($1) }) else { continue }
            if let mappedOld = newToOld[closest.id], let mappedPoint = previousTopLeft(mappedOld),
               (mappedPoint - closest.frame.topLeftCorner).vectorLength <= distance(closest)
            {
                continue // Already taken by a closer previous monitor
            }
            newToOld[closest.id] = oldId
        }

        visibleWorkspaceByMonitor = [:]
        monitorOfVisibleWorkspace = [:]
        for monitor in monitors {
            if let oldId = newToOld[monitor.id], let workspace = oldVisible[oldId], setActiveWorkspace(workspace, on: monitor) {
                continue
            }
            let stub = stubWorkspace(for: monitor)
            setActiveWorkspace(stub, on: monitor)
        }
    }
}
