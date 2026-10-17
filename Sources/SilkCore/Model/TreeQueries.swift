import SilkConfig

extension TreeNode {
    /// Every window below this node, depth first.
    var allLeafWindowsRecursive: [Window] {
        var result: [Window] = []
        collectWindows(into: &result)
        return result
    }

    private func collectWindows(into result: inout [Window]) {
        if let window = self as? Window { result.append(window) }
        for child in children { child.collectWindows(into: &result) }
    }

    var ownIndex: Int? { parent?.children.firstIndex { $0 === self } }

    /// Ancestors, nearest first.
    var parents: [TreeNode] {
        var result: [TreeNode] = []
        var node = parent
        while let current = node {
            result.append(current)
            node = current.parent
        }
        return result
    }

    var parentsWithSelf: [TreeNode] { [self] + parents }

    var nodeWorkspace: Workspace? { self as? Workspace ?? parent?.nodeWorkspace }

    var mostRecentWindowRecursive: Window? { self as? Window ?? mostRecentChild?.mostRecentWindowRecursive }

    var anyLeafWindowRecursive: Window? {
        if let window = self as? Window { return window }
        for child in children {
            if let window = child.anyLeafWindowRecursive { return window }
        }
        return nil
    }

    /// Contains no windows at all.
    var isEffectivelyEmpty: Bool { anyLeafWindowRecursive == nil }

    /// The closest ancestor tiling container (with `layout`, if given) along the direction's orientation that has
    /// a sibling next to the corresponding child in `direction`.
    func closestParent(
        hasChildrenInDirection direction: CardinalDirection,
        withLayout layout: ContainerLayout?
    ) -> (parent: TilingContainer, ownIndex: Int)? {
        let innermostChild = parentsWithSelf.first { node in
            guard let parent = node.parent as? TilingContainer else { return true } // Stop: workspace or special container
            guard (layout == nil || parent.layout == layout) && parent.orientation == direction.orientation else { return false }
            return node.ownIndex.map { parent.children.indices.contains($0 + direction.focusOffset) } ?? true
        }
        guard let innermostChild, let parent = innermostChild.parent as? TilingContainer,
              let ownIndex = innermostChild.ownIndex else { return nil }
        return (parent, ownIndex)
    }

    /// The window on the `direction` side of this subtree: the edge child along the matching orientation,
    /// the most recent child otherwise.
    func findLeafWindowRecursive(snappedTo direction: CardinalDirection) -> Window? {
        switch self {
            case let workspace as Workspace:
                return workspace.rootTilingContainer.findLeafWindowRecursive(snappedTo: direction)
            case let window as Window:
                return window
            case let container as TilingContainer:
                if direction.orientation == container.orientation {
                    let edge = direction.isPositive ? container.children.last : container.children.first
                    return edge?.findLeafWindowRecursive(snappedTo: direction)
                }
                return mostRecentChild?.findLeafWindowRecursive(snappedTo: direction)
            default:
                return nil
        }
    }
}
