import CoreGraphics

/// Weight placeholder for nodes whose parent doesn't use weights (floating, macOS special containers).
let weightDoesntMatter: CGFloat = -2
/// Bind with the average weight of the new siblings (tiling) — "split evenly".
let weightAuto: CGFloat = -1
/// Bind as the last child.
let indexBindLast = -1

/// Where a node was bound before `unbindFromParent()`.
struct BindingData {
    let parent: TreeNode
    let adaptiveWeight: CGFloat
    let index: Int
}

/// A node of the window tree (AeroSpace `TreeNode`).
///
/// Parents own their children; `parent` is weak. Every non-leaf node tracks the most recently used order
/// of its children, which drives focus restoration, accordion layout and new-window placement.
class TreeNode {
    private(set) var children: [TreeNode] = []
    private(set) weak var parent: TreeNode?
    private var adaptiveWeight: CGFloat
    /// Most recent first.
    private(set) var mruChildren: [TreeNode] = []

    /// The rect this node got in the last layout, as if inner gaps were zero. Used by resize-with-mouse
    /// and by `focus` when floating windows are treated as tiling.
    var lastAppliedLayoutVirtualRect: CGRect?
    /// The rect this node got in the last layout (with real gaps). Used by mouse manipulation, `move-mouse`
    /// and focus-follows-mouse.
    var lastAppliedLayoutPhysicalRect: CGRect?
    /// Weight snapshot taken when a resize-with-mouse gesture starts; cleared when it ends.
    var weightBeforeResize: CGFloat?

    init(adaptiveWeight: CGFloat) {
        self.adaptiveWeight = adaptiveWeight
    }

    var isBound: Bool { parent != nil }

    /// Weight along `orientation`. Only meaningful for children of tiling containers (and the root container,
    /// whose weight is its workspace's size).
    func getWeight(_ orientation: Orientation) -> CGFloat {
        guard let parent else {
            assertionFailure("Weight doesn't make sense for nodes without parent")
            return 0
        }
        switch ChildParentRelation(child: self, parent: parent) {
            case .tiling(let container):
                return container.orientation == orientation ? adaptiveWeight : container.getWeight(orientation)
            case .rootTilingContainer:
                return parent.getWeight(orientation)
            default:
                assertionFailure("Weight doesn't make sense for \(self) in \(parent)")
                return 0
        }
    }

    /// Changes the weight along `orientation`. The parent must be a `tiles` container with that orientation.
    func setWeight(_ orientation: Orientation, _ newValue: CGFloat) {
        guard let parent = parent as? TilingContainer, parent.orientation == orientation, parent.layout == .tiles else {
            assertionFailure("Can't change \(orientation) weight of \(self)")
            return
        }
        adaptiveWeight = newValue
    }

    /// Moves this node under `newParent` at `index` (`indexBindLast` appends) and makes it the most recent child
    /// of every ancestor. `weightAuto` gives tiling children the average weight of their new siblings.
    @discardableResult
    func bind(to newParent: TreeNode, adaptiveWeight: CGFloat, index: Int) -> BindingData? {
        let previous = unbindIfBound()
        let relation = ChildParentRelation(child: self, parent: newParent)
        assert(relation != nil, "Illegal child-parent relation: \(self) in \(newParent)")
        if adaptiveWeight == weightAuto {
            if case .tiling(let container) = relation {
                let siblings = container.children
                let sum = siblings.reduce(0) { $0 + $1.getWeight(container.orientation) }
                self.adaptiveWeight = sum.divided(by: siblings.count) ?? 1
            } else {
                self.adaptiveWeight = weightDoesntMatter
            }
        } else {
            self.adaptiveWeight = adaptiveWeight
        }
        newParent.children.insert(self, at: index == indexBindLast ? newParent.children.count : index)
        parent = newParent
        markAsMostRecentChild()
        return previous
    }

    @discardableResult
    func unbindFromParent() -> BindingData {
        guard let data = unbindIfBound() else {
            preconditionFailure("\(self) is already unbound")
        }
        return data
    }

    @discardableResult
    func unbindIfBound() -> BindingData? {
        guard let parent else { return nil }
        guard let index = parent.children.firstIndex(where: { $0 === self }) else {
            preconditionFailure("Can't find child in its parent")
        }
        parent.children.remove(at: index)
        parent.mruChildren.removeAll { $0 === self }
        self.parent = nil
        return BindingData(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    /// Raises this node in its parent's MRU order, recursively up to the root.
    func markAsMostRecentChild() {
        guard let parent else { return }
        parent.mruChildren.removeAll { $0 === self }
        parent.mruChildren.insert(self, at: 0)
        parent.markAsMostRecentChild()
    }

    var mostRecentChild: TreeNode? { mruChildren.first ?? children.last }
}
