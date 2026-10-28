import CoreGraphics

/// Where a window left the tree (ordered out, or reported destroyed), so it can come back to the same slot.
struct WindowSlot {
    weak var parent: TreeNode?
    let workspaceName: String
    let index: Int
    let adaptiveWeight: CGFloat
    let wasFloating: Bool

    init(removedWith data: BindingData, from workspace: Workspace) {
        parent = data.parent
        workspaceName = workspace.name
        index = data.index
        adaptiveWeight = data.adaptiveWeight
        wasFloating = data.parent is FloatingWindowsContainer
    }
}

/// The slot of a window reported destroyed, kept in case it comes back (see `World.rememberClosedWindow`).
struct ClosedWindowSlot {
    let pid: pid_t
    let slot: WindowSlot
    /// Insertion order, for evicting the oldest entry.
    let order: Int
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
        let data = bindingDataForNewWindow(kind: detected.kind, on: workspace)
        let window = makeWindow(detected)
        window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        if !restoreClosedWindowSlot(of: window) && !restorePendingPlacement(of: window) {
            runOnWindowDetected(ifConventional: window)
        }
        return window
    }

    /// A new, unbound window known by id.
    private func makeWindow(_ detected: DetectedWindow) -> Window {
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
        window.isAccessoryApp = detected.isAccessoryApp
        windowsById[window.id] = window
        return window
    }

    /// `detected` takes `replaced`'s place (see `WindowManager.windowReplaced`): same slot, weight and focus.
    /// To the user it's the same window showing another tab, so a new one isn't "opened" (no open animation, no
    /// `on-window-detected`), and a closed tab isn't a closed window (no refocus, no closed-window slot).
    func replace(_ replaced: Window, with detected: DetectedWindow, replacedIsGone: Bool) {
        guard let workspace = replaced.nodeWorkspace else { return }
        let window = windowsById[detected.id] ?? makeWindow(detected)
        window.title = detected.title
        window.lastKnownFrame = detected.frame ?? replaced.lastKnownFrame
        window.pendingInitialFrame = nil
        window.orderedOutSlot = nil
        window.isFullscreen = replaced.isFullscreen
        window.noOuterGapsInFullscreen = replaced.noOuterGapsInFullscreen
        window.lastFloatingSize = replaced.lastFloatingSize
        window.prevUnhiddenProportionalPosition = replaced.prevUnhiddenProportionalPosition
        window.unbindIfBound()
        let wasFocused = focus.window === replaced
        let data = replaced.unbindFromParent()
        window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        if replacedIsGone {
            windowsById[replaced.id] = nil
        } else {
            // Should the tab come back as a window of its own, it goes next to this one
            replaced.orderedOutSlot = WindowSlot(removedWith: data, from: workspace)
        }
        if wasFocused { focusWindow(window) }
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
    ///
    /// `skipClosedWindowsCache` is true when Silk closed the window itself (`close`, `--quit-if-last-window`).
    func garbageCollect(_ window: Window, skipClosedWindowsCache: Bool = false) {
        guard windowsById.removeValue(forKey: window.id) != nil else { return }
        if !skipClosedWindowsCache { touchContainersLikeClosedWindowsCache() }
        let workspace = window.isConventional ? window.nodeWorkspace : nil
        guard let data = window.unbindIfBound() else {
            if !skipClosedWindowsCache, let slot = window.orderedOutSlot { rememberClosedWindow(window, slot: slot) }
            return
        }
        if !skipClosedWindowsCache, let workspace {
            rememberClosedWindow(window, slot: WindowSlot(removedWith: data, from: workspace))
        }
        refocusAfterRemoving(window, from: data.parent)
    }

    /// AeroSpace's closed-windows cache, per window: around the lock screen and display reconfigurations
    /// (closing the lid while docked, unplugging a monitor during sleep) macOS reports live windows as destroyed and
    /// they come back with the same id. Without this they'd be detected as new windows on the focused workspace.
    private func rememberClosedWindow(_ window: Window, slot: WindowSlot) {
        closedWindowSlotCounter += 1
        closedWindowSlots[window.id] = ClosedWindowSlot(pid: window.pid, slot: slot, order: closedWindowSlotCounter)
        if closedWindowSlots.count > World.closedWindowSlotLimit,
           let oldest = closedWindowSlots.min(by: { $0.value.order < $1.value.order })?.key
        {
            closedWindowSlots[oldest] = nil
        }
    }

    /// Puts a just-detected window back where it was when it was reported destroyed. False if it wasn't.
    func restoreClosedWindowSlot(of window: Window) -> Bool {
        guard let closed = closedWindowSlots.removeValue(forKey: window.id), closed.pid == window.pid else { return false }
        window.unbindIfBound()
        bind(window, to: closed.slot)
        moveMenuBarAppWindowToVisibleWorkspace(window) // Electron `menubar` popups are reported destroyed when hidden
        return true
    }

    /// The app quit: its windows are really gone.
    func forgetClosedWindowSlots(pid: pid_t) {
        closedWindowSlots = closedWindowSlots.filter { $0.value.pid != pid }
    }

    /// AeroSpace snapshots the whole world when a window dies on its own (`cacheClosedWindowIfNeeded`, its defence
    /// against the lock screen). Silk keeps each window's slot instead (`rememberClosedWindow`) and reproduces the
    /// snapshot's side effect on the tree: it creates every workspace's root, floating, hidden-apps and fullscreen containers if missing, and each
    /// new container becomes its workspace's most recent child. Until a window of the workspace is marked most recent
    /// again, focusing the workspace focuses its first window.
    private func touchContainersLikeClosedWindowsCache() {
        for workspace in allWorkspaces {
            _ = workspace.rootTilingContainer
            _ = workspace.floatingWindowsContainer
            _ = workspace.macosHiddenAppsWindowsContainer
            _ = workspace.macosFullscreenWindowsContainer
        }
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
        guard window.isConventional, let workspace = window.nodeWorkspace, let data = window.unbindIfBound() else { return }
        window.orderedOutSlot = WindowSlot(removedWith: data, from: workspace)
        refocusAfterRemoving(window, from: data.parent)
    }

    /// An ordered-out window is back.
    func orderIn(_ window: Window) {
        guard let slot = window.orderedOutSlot, window.parent == nil else { return }
        window.orderedOutSlot = nil
        bind(window, to: slot)
        moveMenuBarAppWindowToVisibleWorkspace(window)
    }

    /// A menu bar app's floating window that shows up on a hidden workspace was put up by the app (a menu bar click,
    /// a hotkey): without a Dock icon or cmd-tab entry the user can't have gone to it. It joins the visible workspace
    /// of the monitor it shows on, instead of focus switching to the workspace it was last seen on.
    func moveMenuBarAppWindowToVisibleWorkspace(_ window: Window) {
        guard window.isAccessoryApp, window.isFloating, let workspace = window.nodeWorkspace, !isVisible(workspace) else { return }
        let target = window.isHiddenInCorner
            ? focus.workspace
            : window.lastKnownFrame.map { activeWorkspace(on: monitorApproximation($0.center)) } ?? focus.workspace
        bindAsFloatingWindow(window, to: target)
    }

    /// Returns a window to its slot if that still exists, else to its workspace.
    private func bind(_ window: Window, to slot: WindowSlot) {
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
