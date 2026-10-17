import CoreGraphics

extension World {
    /// The user moved or resized `window` with the mouse to `frame` (AeroSpace move/resize-with-mouse).
    /// A changed size is a resize; otherwise it's a move.
    func handleUserManipulation(_ window: Window, frame: CGRect) {
        // Windows of hidden workspaces can't be manipulated, and one gesture handles one window
        guard !window.isHiddenInCorner, manipulatedWindowId == nil || manipulatedWindowId == window.id else { return }
        let referenceSize = window.lastAppliedLayoutPhysicalRect?.size ?? window.lastKnownFrame?.size
        window.lastKnownFrame = frame
        let isResize = referenceSize.map { abs($0.width - frame.width) > 1 || abs($0.height - frame.height) > 1 } ?? false
        switch window.parent {
            case is FloatingWindowsContainer:
                // Unlike AeroSpace (which never writes floating frames), plans carry floating frames: keep the
                // dragged window out of them until the gesture ends.
                manipulatedWindowId = window.id
                if !isResize { moveFloatingWindow(window, frame: frame) }
            case is TilingContainer:
                if isResize { resizeTilingWindow(window, frame: frame) } else { moveTilingWindow(window) }
            default:
                return // Unconventional windows can't be moved with the mouse
        }
    }

    /// The left mouse button went up: the gesture is over and the dragged window snaps into its tile.
    func endUserManipulation() {
        guard manipulatedWindowId != nil else { return }
        manipulatedWindowId = nil
        for workspace in allWorkspaces {
            workspace.resetWeightBeforeResize()
        }
    }

    /// A floating window dragged onto another monitor joins that monitor's workspace.
    private func moveFloatingWindow(_ window: Window, frame: CGRect) {
        let targetWorkspace = activeWorkspace(on: monitorApproximation(frame.center))
        if window.nodeWorkspace !== targetWorkspace {
            bindAsFloatingWindow(window, to: targetWorkspace)
        }
    }

    /// While dragging a tiled window: dropping it over another tile swaps them; over another monitor it's inserted
    /// next to the tile under the mouse.
    private func moveTilingWindow(_ window: Window) {
        manipulatedWindowId = window.id
        window.lastAppliedLayoutPhysicalRect = nil
        let mouse = platform.mouseLocation
        let targetWorkspace = activeWorkspace(on: monitorApproximation(mouse))
        let swapTarget = mouse.findWindowRecursively(in: targetWorkspace.rootTilingContainer, virtual: false, fullscreenCoversAll: false)
            .flatMap { $0 === window ? nil : $0 }
        if targetWorkspace !== window.nodeWorkspace {
            var index = 0
            if let swapTarget, let parent = swapTarget.parent as? TilingContainer, let targetRect = swapTarget.lastAppliedLayoutPhysicalRect,
               let ownIndex = swapTarget.ownIndex
            {
                index = mouse.projection(parent.orientation) >= targetRect.center.projection(parent.orientation) ? ownIndex + 1 : ownIndex
            }
            window.bind(to: swapTarget?.parent ?? targetWorkspace.rootTilingContainer, adaptiveWeight: weightAuto, index: index)
        } else if let swapTarget {
            swapWindows(mruDominant: window, swapTarget)
        }
    }

    /// While resizing a tiled window: the dragged edges move the weights of the window and its neighbours.
    private func resizeTilingWindow(_ window: Window, frame rect: CGRect) {
        guard let lastAppliedRect = window.lastAppliedLayoutPhysicalRect else { return }
        let left = window.closestParent(hasChildrenInDirection: .left, withLayout: .tiles)
        let down = window.closestParent(hasChildrenInDirection: .down, withLayout: .tiles)
        let up = window.closestParent(hasChildrenInDirection: .up, withLayout: .tiles)
        let right = window.closestParent(hasChildrenInDirection: .right, withLayout: .tiles)
        let table: [(diff: CGFloat, parent: TilingContainer?, startIndex: Int?, pastTheEndIndex: Int?)] = [
            (lastAppliedRect.minX - rect.minX, left?.parent, 0, left?.ownIndex), // To the left of the window
            (rect.maxY - lastAppliedRect.maxY, down?.parent, down.map { $0.ownIndex + 1 }, down?.parent.children.count), // Below
            (lastAppliedRect.minY - rect.minY, up?.parent, 0, up?.ownIndex), // Above
            (rect.maxX - lastAppliedRect.maxX, right?.parent, right.map { $0.ownIndex + 1 }, right?.parent.children.count), // To the right
        ]
        for (diff, parent, startIndex, pastTheEndIndex) in table {
            // 5 points absorb accumulated floating point error
            guard let parent, let startIndex, let pastTheEndIndex, pastTheEndIndex - startIndex > 0, abs(diff) > 5 else { continue }
            let siblingDiff = diff / CGFloat(pastTheEndIndex - startIndex)
            let orientation = parent.orientation
            for node in window.parentsWithSelf.prefix(while: { $0 !== parent }) {
                guard let nodeParent = node.parent as? TilingContainer, nodeParent.orientation == orientation, nodeParent.layout == .tiles else { continue }
                node.setWeight(orientation, node.weightBeforeResizeSnapshot(orientation) + diff)
            }
            for sibling in parent.children[startIndex ..< pastTheEndIndex] {
                sibling.setWeight(orientation, sibling.weightBeforeResizeSnapshot(orientation) - siblingDiff)
            }
        }
        manipulatedWindowId = window.id
    }

    /// Focus follows mouse: focuses the floating window under `point` (most recent first) or the tile under it.
    /// The platform calls this only when an AX window is under the mouse.
    func focusFollowsMouse(at point: CGPoint) -> Window? {
        let workspace = activeWorkspace(on: monitorApproximation(point))
        let floatingContainer = workspace.children.first { $0 is FloatingWindowsContainer }
        let floating = (floatingContainer?.mruChildren ?? []).lazy
            .compactMap { $0 as? Window }
            .first { $0.lastKnownFrame?.containsPoint(point) == true }
        return floating ?? point.findWindowRecursively(in: workspace.rootTilingContainer, virtual: false, fullscreenCoversAll: true)
    }
}

extension TreeNode {
    /// The weight when the current resize gesture started, from the last layout's virtual rect.
    fileprivate func weightBeforeResizeSnapshot(_ orientation: Orientation) -> CGFloat {
        if let weightBeforeResize { return weightBeforeResize }
        let weight = lastAppliedLayoutVirtualRect?.dimension(orientation) ?? getWeight(orientation)
        weightBeforeResize = weight
        return weight
    }

    fileprivate func resetWeightBeforeResize() {
        weightBeforeResize = nil
        for child in children { child.resetWeightBeforeResize() }
    }
}

extension CGPoint {
    /// The tiled window whose last applied rect contains this point (accordions resolve to their most recent child).
    func findWindowRecursively(in tree: TilingContainer, virtual: Bool, fullscreenCoversAll: Bool) -> Window? {
        if fullscreenCoversAll, let window = tree.mostRecentWindowRecursive, window.isFullscreen {
            return window
        }
        let target: TreeNode? = switch tree.layout {
            case .tiles: tree.children.first { (virtual ? $0.lastAppliedLayoutVirtualRect : $0.lastAppliedLayoutPhysicalRect)?.containsPoint(self) == true }
            case .accordion: tree.mostRecentChild
        }
        switch target {
            case let window as Window: return window
            case let container as TilingContainer: return findWindowRecursively(in: container, virtual: virtual, fullscreenCoversAll: false)
            default: return nil
        }
    }
}
