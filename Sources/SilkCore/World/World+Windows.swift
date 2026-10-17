import CoreGraphics

/// Where an ordered-out window was, so it can come back to the same slot.
struct OrderedOutSlot {
    weak var parent: TreeNode?
    let workspaceName: String
    let index: Int
    let adaptiveWeight: CGFloat
    let wasFloating: Bool
}

extension World {
    /// Adds a newly discovered window to the tree (AeroSpace `MacWindow.getOrRegister`) and runs
    /// `on-window-detected` unless a restored placement claimed it.
    @discardableResult
    func register(_ detected: DetectedWindow, bindByMonitorUnderCenter: Bool) -> Window {
        if let existing = windowsById[detected.id] { return existing }
        let workspace = bindByMonitorUnderCenter
            ? activeWorkspace(on: detected.frame.map { monitorApproximation($0.center) } ?? mainMonitor)
            : focus.workspace
        let window = Window(
            id: detected.id,
            pid: detected.pid,
            bundleId: detected.bundleId,
            appName: detected.appName,
            title: detected.title,
            kind: detected.kind,
            frame: detected.frame
        )
        window.isMacosMinimized = detected.isMinimized
        window.isMacosFullscreen = detected.isFullscreen
        let data = bindingDataForNewWindow(kind: detected.kind, on: workspace)
        window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        windowsById[window.id] = window
        if !restorePendingPlacement(of: window) {
            runOnWindowDetected(ifConventional: window)
        }
        return window
    }

    /// Where a new (or re-laid-out) window goes: popups to the popup container, dialogs float, windows tile next
    /// to the workspace's most recent window. Unbinds `window` for tiling so it doesn't count as the MRU.
    func bindingDataForNewWindow(kind: WindowKind, on workspace: Workspace, window: Window? = nil) -> BindingData {
        switch kind {
            case .popup: BindingData(parent: popupContainer, adaptiveWeight: weightAuto, index: indexBindLast)
            case .dialog: BindingData(parent: workspace.floatingWindowsContainer, adaptiveWeight: weightAuto, index: indexBindLast)
            case .window: bindingDataForNewTilingWindow(on: workspace, window: window)
        }
    }

    func bindingDataForNewTilingWindow(on workspace: Workspace, window: Window?) -> BindingData {
        window?.unbindIfBound() // Unbind first to get correct MRU data
        if let mruWindow = workspace.mostRecentWindowRecursive, let tilingParent = mruWindow.parent as? TilingContainer,
           let index = mruWindow.ownIndex
        {
            return BindingData(parent: tilingParent, adaptiveWeight: weightAuto, index: index + 1)
        }
        return BindingData(parent: workspace.rootTilingContainer, adaptiveWeight: weightAuto, index: indexBindLast)
    }

    func relayoutWindow(_ window: Window, on workspace: Workspace, forceTile: Bool = false) {
        let data = forceTile
            ? bindingDataForNewTilingWindow(on: workspace, window: window)
            : bindingDataForNewWindow(kind: window.kind, on: workspace, window: window)
        window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
    }

    func bindAsFloatingWindow(_ window: Window, to workspace: Workspace) {
        window.bind(to: workspace.floatingWindowsContainer, adaptiveWeight: weightAuto, index: indexBindLast)
    }

    /// Forgets a closed window (AeroSpace `MacWindow.garbageCollect`). If it was on the focused workspace (or the
    /// one focused less than a second ago), focus moves to that workspace's most recent window — natively too when
    /// that window belongs to another app, because macOS would otherwise keep a windowless app focused.
    func garbageCollect(_ window: Window) {
        guard windowsById.removeValue(forKey: window.id) != nil else { return }
        guard let parent = window.unbindIfBound()?.parent else { return }
        refocusAfterRemoving(window, from: parent)
    }

    private func refocusAfterRemoving(_ window: Window, from parent: TreeNode) {
        guard let deadWindowWorkspace = parent.nodeWorkspace else { return }
        let focus = self.focus
        let wasRecentlyFocused = deadWindowWorkspace === prevFocusedWorkspace
            && now().timeIntervalSince(prevFocusedWorkspaceDate) < 1
        guard deadWindowWorkspace === focus.workspace || wasRecentlyFocused else { return }
        switch parent {
            case is TilingContainer, is FloatingWindowsContainer, is MacosHiddenAppsWindowsContainer, is MacosFullscreenWindowsContainer:
                let deadWindowFocus = liveFocus(of: deadWindowWorkspace)
                setFocus(deadWindowFocus)
                if focus.window?.pid != window.pid, let newWindow = deadWindowFocus.window {
                    platform.focus(window: newWindow.id, pid: newWindow.pid)
                }
            default:
                break // Popups and minimized windows don't steal focus back
        }
    }

    /// The window is still alive but off screen (another Space, Electron `hide()`): drop it from the tree but
    /// remember its slot.
    func orderOut(_ window: Window) {
        guard window.isConventional, let parent = window.parent, let workspace = window.nodeWorkspace,
              let data = window.unbindIfBound() else { return }
        window.orderedOutSlot = OrderedOutSlot(
            parent: parent,
            workspaceName: workspace.name,
            index: data.index,
            adaptiveWeight: data.adaptiveWeight,
            wasFloating: parent is FloatingWindowsContainer
        )
        refocusAfterRemoving(window, from: parent)
    }

    /// An ordered-out window is back: return it to its slot if that still exists, else to its workspace.
    func orderIn(_ window: Window) {
        guard let slot = window.orderedOutSlot, window.parent == nil else { return }
        window.orderedOutSlot = nil
        if let parent = slot.parent, parent.nodeWorkspace?.name == slot.workspaceName {
            window.bind(to: parent, adaptiveWeight: slot.adaptiveWeight, index: min(slot.index, parent.children.count))
        } else if slot.wasFloating {
            bindAsFloatingWindow(window, to: workspace(named: slot.workspaceName))
        } else {
            relayoutWindow(window, on: workspace(named: slot.workspaceName), forceTile: true)
        }
    }

    /// Moves windows into and out of the macOS special containers according to their reported state
    /// (AeroSpace `normalizeLayoutReason`).
    func normalizeLayoutReason() {
        for workspace in allWorkspaces {
            normalizeLayoutReason(workspace: workspace, windows: workspace.allLeafWindowsRecursive)
        }
        normalizeLayoutReason(workspace: focus.workspace, windows: minimizedContainer.children.compactMap { $0 as? Window })
    }

    private func normalizeLayoutReason(workspace: Workspace, windows: [Window]) {
        for window in windows {
            let isFullscreen = window.isMacosFullscreen
            let isMinimized = !isFullscreen && window.isMacosMinimized
            let isWindowOfHiddenApp = !isFullscreen && !isMinimized && !config.automaticallyUnhideMacosHiddenApps
                && hiddenApps.contains(window.pid)
            switch window.layoutReason {
                case .standard:
                    guard let parent = window.parent, let parentKind = NonLeafNodeKind(parent) else { continue }
                    if isFullscreen {
                        window.layoutReason = .macos(prevParentKind: parentKind)
                        window.bind(to: workspace.macosFullscreenWindowsContainer, adaptiveWeight: weightDoesntMatter, index: indexBindLast)
                    } else if isMinimized {
                        window.layoutReason = .macos(prevParentKind: parentKind)
                        window.bind(to: minimizedContainer, adaptiveWeight: 1, index: indexBindLast)
                    } else if isWindowOfHiddenApp {
                        window.layoutReason = .macos(prevParentKind: parentKind)
                        window.bind(to: workspace.macosHiddenAppsWindowsContainer, adaptiveWeight: weightDoesntMatter, index: indexBindLast)
                    }
                case .macos(let prevParentKind):
                    if !isFullscreen && !isMinimized && !isWindowOfHiddenApp {
                        exitMacosNativeUnconventionalState(window, prevParentKind: prevParentKind, workspace: workspace)
                    }
            }
        }
    }

    func exitMacosNativeUnconventionalState(_ window: Window, prevParentKind: NonLeafNodeKind, workspace: Workspace) {
        window.layoutReason = .standard
        switch prevParentKind {
            case .floatingWindowsContainer:
                bindAsFloatingWindow(window, to: workspace)
            case .workspace:
                break // Not possible
            case .tilingContainer:
                relayoutWindow(window, on: workspace, forceTile: true)
            case .macosPopupWindowsContainer, .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosHiddenAppsWindowsContainer:
                // Mistakenly detected as a popup while minimized/fullscreen, or a state that shouldn't happen
                relayoutWindow(window, on: workspace)
        }
    }

    /// Re-classified by the platform: a former popup that turned out to be a real window is laid out and
    /// detected now (AeroSpace `validateStillPopups`).
    func reclassify(_ window: Window, as kind: WindowKind) {
        window.kind = kind
        guard window.parent is MacosPopupWindowsContainer, kind != .popup else { return }
        relayoutWindow(window, on: focus.workspace)
        runOnWindowDetected(ifConventional: window)
    }
}
