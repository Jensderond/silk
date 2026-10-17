extension Workspace {
    /// AeroSpace normalizations: drop empty containers, flatten single-child containers, and alternate nested
    /// container orientations.
    func normalizeContainers(flatten: Bool, oppositeOrientation: Bool) {
        rootTilingContainer.unbindEmptyAndAutoFlatten(flatten: flatten) // The root container may be replaced
        if oppositeOrientation {
            rootTilingContainer.normalizeOppositeOrientationForNestedContainers()
        }
    }
}

extension TilingContainer {
    fileprivate func unbindEmptyAndAutoFlatten(flatten: Bool) {
        if let child = children.count == 1 ? children[0] : nil, flatten && (child is TilingContainer || !isRootContainer) {
            child.unbindFromParent()
            let mru = parent?.mostRecentChild
            let previousBinding = unbindFromParent()
            child.bind(to: previousBinding.parent, adaptiveWeight: previousBinding.adaptiveWeight, index: previousBinding.index)
            (child as? TilingContainer)?.unbindEmptyAndAutoFlatten(flatten: flatten)
            if mru !== self {
                mru?.markAsMostRecentChild()
            } else {
                child.markAsMostRecentChild()
            }
        } else {
            for case let child as TilingContainer in children {
                child.unbindEmptyAndAutoFlatten(flatten: flatten)
            }
            if children.isEmpty && !isRootContainer {
                unbindFromParent()
            }
        }
    }
}
