import CoreGraphics
import SilkConfig

/// A restored snapshot whose windows haven't all been detected yet.
struct PendingRestore {
    var workspaces: [FrozenWorkspace]
    var focusedWindowId: WindowID?
    /// Windows of the snapshot that have been placed so far.
    var placedWindowIds: Set<WindowID> = []
}

extension World {
    func frozenWorld() -> FrozenWorld {
        let workspaces = allWorkspaces.filter { !$0.isEffectivelyEmpty || isVisible($0) }.map { workspace in
            FrozenWorkspace(
                name: workspace.name,
                monitorId: monitor(of: workspace).id,
                root: freeze(workspace.rootTilingContainer),
                floatingWindows: workspace.floatingWindows.map(freeze),
                macosUnconventionalWindows: workspace.macosUnconventionalWindows.map(freeze)
            )
        }
        let focus = self.focus
        return FrozenWorld(
            workspaces: workspaces,
            visibleWorkspaces: visibleWorkspaceByMonitor.mapValues(\.name),
            focusedWorkspace: focus.workspace.name,
            focusedWindowId: focus.window?.id
        )
    }

    private func freeze(_ container: TilingContainer) -> FrozenContainer {
        FrozenContainer(
            layout: container.layout == .tiles ? .tiles : .accordion,
            orientation: container.orientation == .h ? .horizontal : .vertical,
            weight: Double(tilingWeight(of: container) ?? 1),
            children: container.children.compactMap { child in
                switch child {
                    case let window as Window: .window(freeze(window))
                    case let container as TilingContainer: .container(freeze(container))
                    default: nil
                }
            }
        )
    }

    private func freeze(_ window: Window) -> FrozenWindow {
        FrozenWindow(
            id: window.id,
            weight: Double(tilingWeight(of: window) ?? 1),
            frame: window.isFloating ? (unhiddenFloatingFrame(window) ?? window.lastKnownFrame) : nil,
            lastFloatingSize: window.lastFloatingSize
        )
    }

    private func tilingWeight(of node: TreeNode) -> CGFloat? {
        (node.parent as? TilingContainer).map { node.getWeight($0.orientation) }
    }

    /// Applies the snapshot's monitor assignment and focus now, and places its windows as they are detected
    /// (already known windows immediately). Restored windows don't run `on-window-detected`.
    func restore(_ frozen: FrozenWorld) {
        didRestoreSnapshot = true
        for frozenWorkspace in frozen.workspaces {
            let workspace = workspace(named: frozenWorkspace.name)
            if !isVisible(workspace) { workspace.assignedMonitorId = frozenWorkspace.monitorId }
        }
        for (monitorId, name) in frozen.visibleWorkspaces.sorted(by: { $0.key < $1.key }) {
            if let monitor = monitor(id: monitorId) { setActiveWorkspace(workspace(named: name), on: monitor) }
        }
        focusWorkspace(workspace(named: frozen.focusedWorkspace))
        pendingRestore = PendingRestore(workspaces: frozen.workspaces, focusedWindowId: frozen.focusedWindowId)
        for window in allWindows where frozen.windowIds.contains(window.id) {
            _ = restorePendingPlacement(of: window)
        }
    }

    /// Places a just-detected window according to the pending snapshot. False if the snapshot doesn't know it.
    func restorePendingPlacement(of window: Window) -> Bool {
        guard var pending = pendingRestore,
              let index = pending.workspaces.firstIndex(where: { frozen in
                  frozen.root.windowIds.contains(window.id) || (frozen.floatingWindows + frozen.macosUnconventionalWindows).contains { $0.id == window.id }
              })
        else { return false }
        pending.placedWindowIds.insert(window.id)
        let frozenWorkspace = pending.workspaces[index]
        rebuild(frozenWorkspace, placed: pending.placedWindowIds)

        if window.id == pending.focusedWindowId {
            focusWindow(window)
            pending.focusedWindowId = nil
        }
        let allIds = Set(frozenWorkspace.root.windowIds + (frozenWorkspace.floatingWindows + frozenWorkspace.macosUnconventionalWindows).map(\.id))
        if allIds.isSubset(of: pending.placedWindowIds) { pending.workspaces.remove(at: index) }
        pendingRestore = pending.workspaces.isEmpty ? nil : pending
        return true
    }

    /// Rebuilds a workspace's tree from the snapshot with the windows placed so far.
    private func rebuild(_ frozen: FrozenWorkspace, placed: Set<WindowID>) {
        let workspace = workspace(named: frozen.name)
        func restorable(_ id: WindowID) -> Window? {
            guard placed.contains(id), let window = windowsById[id], window.isConventional else { return nil }
            return window
        }
        for frozenWindow in frozen.floatingWindows + frozen.macosUnconventionalWindows {
            guard let window = restorable(frozenWindow.id) else { continue }
            bindAsFloatingWindow(window, to: workspace)
            if let frame = frozenWindow.frame { window.lastKnownFrame = frame }
            if let size = frozenWindow.lastFloatingSize { window.lastFloatingSize = size }
        }
        let previousRoot = workspace.rootTilingContainer
        let potentialOrphans = previousRoot.allLeafWindowsRecursive
        previousRoot.unbindFromParent()
        build(frozen.root, parent: workspace, restorable: restorable)
        for orphan in potentialOrphans where orphan.nodeWorkspace !== workspace {
            relayoutWindow(orphan, on: workspace, forceTile: true)
        }
    }

    private func build(_ frozen: FrozenContainer, parent: TreeNode, restorable: (WindowID) -> Window?) {
        let container = TilingContainer(
            parent: parent,
            adaptiveWeight: CGFloat(frozen.weight),
            frozen.orientation == .horizontal ? .h : .v,
            frozen.layout == .tiles ? ContainerLayout.tiles : .accordion,
            index: indexBindLast
        )
        for child in frozen.children {
            switch child {
                case .window(let frozenWindow):
                    restorable(frozenWindow.id)?.bind(to: container, adaptiveWeight: CGFloat(frozenWindow.weight), index: indexBindLast)
                case .container(let frozenContainer):
                    build(frozenContainer, parent: container, restorable: restorable)
            }
        }
    }
}
