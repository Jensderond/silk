/// Focus "frozen in time": safe to keep, but its window/workspace/monitor may have drifted apart since.
struct FrozenFocus: Equatable {
    var windowId: WindowID?
    var workspaceName: String
    /// 1-based monitor id. Not part of the focus itself; kept for `on-focused-monitor-changed`.
    var monitorId: Int
}

/// Focus resolved against the current tree. Don't store it.
struct LiveFocus: Equatable {
    var window: Window?
    var workspace: Workspace

    static func == (lhs: LiveFocus, rhs: LiveFocus) -> Bool {
        lhs.window === rhs.window && lhs.workspace === rhs.workspace
    }
}

extension World {
    var focus: LiveFocus { live(focusState) }

    func live(_ frozen: FrozenFocus) -> LiveFocus {
        let workspaceFocus = liveFocus(of: workspace(named: frozen.workspaceName))
        let windowFocus = frozen.windowId.flatMap(window(byId:)).flatMap(liveFocusOrNil) ?? workspaceFocus
        // If window and workspace drifted apart, prefer the workspace
        return workspaceFocus.workspace !== windowFocus.workspace ? workspaceFocus : windowFocus
    }

    func frozen(_ focus: LiveFocus) -> FrozenFocus {
        FrozenFocus(
            windowId: focus.window?.id,
            workspaceName: focus.workspace.name,
            monitorId: monitorId1Based(monitor(of: focus.workspace)) ?? 0
        )
    }

    /// Focuses the workspace's most recent window (or the empty workspace).
    func liveFocus(of workspace: Workspace) -> LiveFocus {
        LiveFocus(window: workspace.mostRecentWindowRecursive ?? workspace.anyLeafWindowRecursive, workspace: workspace)
    }

    /// Nil for windows outside any workspace (minimized, popups, unbound).
    func liveFocusOrNil(_ window: Window) -> LiveFocus? {
        window.nodeWorkspace.map { LiveFocus(window: window, workspace: $0) }
    }

    /// Makes `newFocus` the focus and shows its workspace on its monitor. False if the workspace can't be shown
    /// there (force assignment).
    @discardableResult
    func setFocus(_ newFocus: LiveFocus) -> Bool {
        if focusState == frozen(newFocus) { return true }
        let oldFocus = focus
        // Normalize MRU when focus leaves a workspace
        if oldFocus.workspace !== newFocus.workspace {
            oldFocus.window?.markAsMostRecentChild()
        }
        focusState = frozen(newFocus)
        let status = setActiveWorkspace(newFocus.workspace, on: monitor(of: newFocus.workspace))
        newFocus.window?.markAsMostRecentChild()
        return status
    }

    @discardableResult
    func focusWindow(_ window: Window) -> Bool {
        guard let focus = liveFocusOrNil(window) else { return false }
        return setFocus(focus)
    }

    @discardableResult
    func focusWorkspace(_ workspace: Workspace) -> Bool { setFocus(liveFocus(of: workspace)) }

    /// For `focus-back-and-forth`: the previous focus, unless it is the current one.
    var prevFocusLive: LiveFocus? {
        guard let prevFocus else { return nil }
        let live = live(prevFocus)
        return live == focus ? nil : live
    }

    /// For `workspace-back-and-forth`.
    var prevFocusedWorkspace: Workspace? { prevFocusedWorkspaceName.map(workspace(named:)) }

    /// macOS reports a newly focused window: make it the focus (AeroSpace `updateFocusCache`).
    func syncFocusFromNative(_ nativeFocused: Window?) {
        if nativeFocused?.parent is MacosPopupWindowsContainer { return }
        if nativeFocused?.id != lastKnownNativeFocusedWindowId {
            if let nativeFocused { focusWindow(nativeFocused) }
            lastKnownNativeFocusedWindowId = nativeFocused?.id
        }
        if let nativeFocused { debugWindowsRecorder.record(nativeFocused, world: self) }
    }
}
