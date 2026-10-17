import Testing
@testable import SilkCore

// Ported from AeroSpace's TreeNodeTest.

@Suite struct TreeNodeTests {
    let t = TestHarness()

    @Test func unbindingTheRootDetachesItsWindows() {
        let workspace = t.workspace("a")
        let window = t.window(1, in: workspace.rootTilingContainer)
        #expect(window.parent != nil)
        workspace.rootTilingContainer.unbindFromParent()
        #expect(window.nodeWorkspace == nil)
    }

    @Test func isEffectivelyEmpty() {
        let workspace = t.workspace("a")
        #expect(workspace.isEffectivelyEmpty)
        let window = t.window(1, in: workspace.rootTilingContainer)
        #expect(!workspace.isEffectivelyEmpty)
        window.unbindFromParent()
        #expect(workspace.isEffectivelyEmpty)
    }

    @Test func normalizationKeepsTheRoot() {
        let workspace = t.workspace("a")
        let root = workspace.rootTilingContainer
        workspace.normalizeContainers(flatten: false, oppositeOrientation: false)
        #expect(workspace.rootTilingContainer === root)
        workspace.normalizeContainers(flatten: true, oppositeOrientation: false)
        #expect(workspace.rootTilingContainer === root)
    }

    @Test func normalizationFlattensSingleWindowChild() {
        let workspace = t.workspace("a")
        let root = workspace.rootTilingContainer
        t.window(0, in: root)
        t.window(1, in: t.hTiles(root))
        workspace.normalizeContainers(flatten: true, oppositeOrientation: false)
        #expect(workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(0), .window(1)]))
    }

    @Test func normalizationRemovesEffectivelyEmptyContainers() {
        let workspace = t.workspace("a")
        t.hTiles(t.vTiles(workspace.rootTilingContainer))
        #expect(workspace.rootTilingContainer.children.count == 1)
        workspace.normalizeContainers(flatten: false, oppositeOrientation: false)
        #expect(workspace.rootTilingContainer.children.isEmpty)
    }

    @Test func normalizationFlattensContainers() {
        let workspace = t.workspace("a")
        t.window(1, in: t.vTiles(workspace.rootTilingContainer))
        workspace.normalizeContainers(flatten: false, oppositeOrientation: false)
        #expect(workspace.rootTilingContainer.children.first is TilingContainer)
        workspace.normalizeContainers(flatten: true, oppositeOrientation: false)
        #expect(workspace.rootTilingContainer.children.first is Window)
    }

    @Test func flatteningARootWithASingleContainerKeepsTheContainersLayout() {
        let workspace = t.workspace("a")
        let column = t.vTiles(workspace.rootTilingContainer)
        t.window(1, in: column)
        t.window(2, in: column)
        workspace.normalizeContainers(flatten: true, oppositeOrientation: true)
        #expect(workspace.rootTilingContainer === column)
        #expect(workspace.layoutDescription == .workspace([.v_tiles([.window(1), .window(2)])]))
    }

    @Test func oppositeOrientationNormalization() {
        let workspace = t.workspace("a")
        let root = workspace.rootTilingContainer
        t.window(1, in: root)
        let nested = t.hTiles(root)
        t.window(2, in: nested)
        t.window(3, in: t.hTiles(nested))
        workspace.normalizeContainers(flatten: false, oppositeOrientation: true)
        #expect(root.layoutDescription == .h_tiles([.window(1), .v_tiles([.window(2), .h_tiles([.window(3)])])]))
    }

    @Test func mruAndWeights() {
        let root = t.workspace("a").rootTilingContainer
        let window1 = t.window(1, in: root, weight: 2)
        let window2 = t.window(2, in: root, weight: weightAuto) // average of the siblings
        #expect(window2.hWeight == 2)
        #expect(root.mostRecentChild === window2)
        window1.markAsMostRecentChild()
        #expect(root.mostRecentChild === window1)
        #expect(window1.vWeight == root.vWeight) // Across the orientation, a child has its parent's weight
        #expect(root.hWeight == 1920) // The root's weight is the monitor's size
    }

    @Test func closestParent() {
        let root = t.workspace("a").rootTilingContainer
        t.window(1, in: root)
        let column = t.vTiles(root)
        let window2 = t.window(2, in: column)
        t.window(3, in: column)
        #expect(window2.closestParent(hasChildrenInDirection: .left, withLayout: nil).map { ($0.parent === root, $0.ownIndex) }! == (true, 1))
        #expect(window2.closestParent(hasChildrenInDirection: .down, withLayout: nil).map { ($0.parent === column, $0.ownIndex) }! == (true, 0))
        #expect(window2.closestParent(hasChildrenInDirection: .up, withLayout: nil) == nil)
        #expect(window2.closestParent(hasChildrenInDirection: .right, withLayout: nil) == nil)
        #expect(window2.closestParent(hasChildrenInDirection: .left, withLayout: .accordion) == nil)
    }

    @Test func logicalSegmentsOrderWorkspaces() {
        let names = ["10", "b", "2", "a10", "a2", "1", "B"]
        #expect(names.sorted { LogicalSegments($0) < LogicalSegments($1) } == ["1", "2", "10", "B", "a2", "a10", "b"])
    }
}
