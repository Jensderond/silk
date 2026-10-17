import CoreGraphics
import Testing
@testable import SilkCore

@Suite struct ResizeCommandTests {
    let t = TestHarness()

    @Test func parse() {
        func units(_ script: String) -> (ResizeCommand.Dimension, ResizeCommand.Units)? {
            parseSingle(script, as: ResizeCommand.self).map { ($0.dimension, $0.units) }
        }
        #expect(units("resize smart +10")! == (.smart, .add(10)))
        #expect(units("resize smart -10")! == (.smart, .subtract(10)))
        #expect(units("resize smart 10")! == (.smart, .set(10)))
        #expect(units("resize smart-opposite -10")! == (.smartOpposite, .subtract(10)))
        #expect(units("resize height 10")! == (.height, .set(10)))
        #expect(units("resize width 10")! == (.width, .set(10)))
        #expect(parseScript("resize s 10").errorOrNil == "ERROR: Can't parse 's'.\n       Possible values: (width|height|smart|smart-opposite)")
        #expect(parseScript("resize smart foo").errorOrNil == "ERROR: <number> argument must be a number")
        #expect(parseScript("resize smart").errorOrNil == "ERROR: Argument '[+|-]<number>' is mandatory")
    }

    @Test func widthAddGrowsTargetAndShrinksSiblings() {
        let root = t.workspace("a").rootTilingContainer
        let window1 = t.window(1, in: root, weight: 4)
        let window2 = t.window(2, in: root, weight: 4)
        let window3 = t.window(3, in: root, weight: 4)
        t.focus(window1)
        t.run("resize width +2")
        #expect(window1.hWeight == 6)
        #expect(window2.hWeight == 3)
        #expect(window3.hWeight == 3)
    }

    @Test func widthSubtractAndSet() {
        let root = t.workspace("a").rootTilingContainer
        let window1 = t.window(1, in: root, weight: 4)
        let window2 = t.window(2, in: root, weight: 4)
        let window3 = t.window(3, in: root, weight: 4)
        t.focus(window1)
        t.run("resize width -2")
        #expect(window1.hWeight == 2)
        #expect(window2.hWeight == 5)
        #expect(window3.hWeight == 5)
        t.run("resize width 6")
        #expect(window1.hWeight == 6)
        #expect(window2.hWeight == 3)
        #expect(window3.hWeight == 3)
    }

    @Test func heightClimbsToVerticalAncestor() {
        let root = t.workspace("a").rootTilingContainer
        t.window(0, in: root)
        let column = t.vTiles(root)
        let window1 = t.window(1, in: column, weight: 4)
        let window2 = t.window(2, in: column, weight: 4)
        t.focus(window1)
        t.run("resize height +2")
        #expect(window1.vWeight == 6)
        #expect(window2.vWeight == 2)
    }

    @Test func smartUsesImmediateParentOrientation() {
        let root = t.workspace("a").rootTilingContainer
        let column = t.vTiles(root, weight: 4)
        let window1 = t.window(1, in: column, weight: 4)
        let window2 = t.window(2, in: column, weight: 4)
        let sibling = t.window(3, in: root, weight: 4)
        t.focus(window1)
        t.run("resize smart +2")
        #expect(window1.vWeight == 6)
        #expect(window2.vWeight == 2)
        #expect(sibling.hWeight == 4)
    }

    @Test func smartOppositeResizesAncestorContainer() {
        let root = t.workspace("a").rootTilingContainer
        let column = t.vTiles(root, weight: 4)
        let inner = t.window(1, in: column)
        t.window(2, in: column)
        let sibling = t.window(3, in: root, weight: 4)
        t.focus(inner)
        t.run("resize smart-opposite +2")
        #expect(column.hWeight == 6)
        #expect(sibling.hWeight == 2)
    }

    @Test func failures() {
        let root = t.workspace("a").rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        #expect(t.run("resize height +2").exitCode == 2)

        let single = t.workspace("b").rootTilingContainer
        #expect(t.focus(t.window(3, in: single, weight: 4)))
        #expect(t.run("resize width +2").exitCode == 2)

        #expect(t.focus(t.window(4, in: t.workspace("c").floatingWindowsContainer)))
        #expect(t.run("resize smart +50").stderr == "resize command doesn't support floating windows yet https://github.com/nikitabobko/AeroSpace/issues/9")
    }

    @Test func smartResizeWithPixelWeightsAfterLayout() {
        // The user's `alt-equal = 'resize smart +50'` on two tiles of a 1920 pt wide monitor
        let root = t.workspace("a").rootTilingContainer
        let window1 = t.window(1, in: root)
        let window2 = t.window(2, in: root)
        t.focus(window1)
        _ = t.manager.computeLayout()
        #expect(window1.hWeight == 960)
        t.run("resize smart +50")
        #expect(window1.hWeight == 1010)
        #expect(window2.hWeight == 910)
        let plan = t.manager.computeLayout()
        #expect(plan.frames[1] == CGRect(x: 0, y: 0, width: 1010, height: 1079))
        #expect(plan.frames[2] == CGRect(x: 1010, y: 0, width: 910, height: 1079))
    }
}

@Suite struct SplitCommandTests {
    let t = TestHarness()

    @Test func split() {
        let root = t.workspace("a").rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        t.run("split vertical")
        #expect(root.layoutDescription == .h_tiles([.v_tiles([.window(1)]), .window(2)]))
    }

    @Test func splitOpposite() {
        let root = t.workspace("a").rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        t.run("split opposite")
        #expect(root.layoutDescription == .h_tiles([.v_tiles([.window(1)]), .window(2)]))
    }

    @Test func singleChildChangesOrientation() {
        let root = t.workspace("a").rootTilingContainer
        #expect(t.focus(t.window(1, in: t.vTiles(root))))
        t.window(2, in: root)
        t.run("split horizontal")
        #expect(root.layoutDescription == .h_tiles([.h_tiles([.window(1)]), .window(2)]))
    }

    @Test func toggleOrientation() {
        let root = t.workspace("a").rootTilingContainer
        #expect(t.focus(t.window(1, in: t.vTiles(root))))
        t.window(2, in: root)
        t.run("split opposite")
        #expect(root.layoutDescription == .h_tiles([.h_tiles([.window(1)]), .window(2)]))
    }

    @Test func failsWithFlattenNormalization() {
        let t = TestHarness(config: testConfig { $0.enableNormalizationFlattenContainers = true })
        let result = t.run("split vertical")
        #expect(result.exitCode == 2)
        #expect(result.stderr.hasPrefix("'split' has no effect when 'enable-normalization-flatten-containers' normalization enabled."))
    }
}

@Suite struct JoinFlattenBalanceCloseTests {
    let t = TestHarness()

    @Test func joinWith() {
        let root = t.workspace("a").rootTilingContainer
        t.window(0, in: root)
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        t.run("join-with right")
        #expect(root.layoutDescription == .h_tiles([.window(0), .v_tiles([.window(1), .window(2)])]))
    }

    @Test func joinWithLeftAppendsTheWindow() {
        let root = t.workspace("a").rootTilingContainer
        t.window(0, in: root)
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        t.run("join-with left")
        #expect(root.layoutDescription == .h_tiles([.v_tiles([.window(0), .window(1)]), .window(2)]))
        t.focus(t.world.window(byId: 2)!)
        #expect(t.run("join-with up") == CommandResult(exitCode: 2, stderr: "No windows in the specified direction"))
    }

    @Test func joinWithWithNormalizationsLikeTheUsersConfig() {
        let t = TestHarness(config: testConfig {
            $0.enableNormalizationFlattenContainers = true
            $0.enableNormalizationOppositeOrientationForNestedContainers = true
        })
        let root = t.workspace("a").rootTilingContainer
        t.window(1, in: root)
        #expect(t.focus(t.window(2, in: root)))
        t.window(3, in: root)
        t.run("join-with left")
        t.run("mode main")
        #expect(root.layoutDescription == .h_tiles([.v_tiles([.window(1), .window(2)]), .window(3)]))
        // The root ends up with a single child: it's flattened and orientations alternate again
        t.focus(t.world.window(byId: 3)!)
        t.run("join-with left")
        #expect(t.workspace("a").rootTilingContainer.layoutDescription == .v_tiles([.h_tiles([.window(1), .window(2)]), .window(3)]))
    }

    @Test func flattenWorkspaceTree() {
        let workspace = t.workspace("a")
        t.window(1, in: workspace.rootTilingContainer)
        t.window(2, in: t.hTiles(workspace.rootTilingContainer))
        t.window(3, in: workspace.floatingWindowsContainer)
        #expect(t.world.focusWorkspace(workspace))
        t.run("flatten-workspace-tree")
        #expect(workspace.layoutDescription == .workspace([.h_tiles([.window(1), .window(2)]), .floatingWindowsContainer([.window(3)])]))
    }

    @Test func balanceSizes() {
        let workspace = t.workspace("a")
        let root = workspace.rootTilingContainer
        t.window(1, in: root, weight: 1)
        t.window(2, in: root, weight: 2)
        let column = t.vTiles(root, weight: 3)
        t.window(3, in: column, weight: 5)
        t.window(4, in: column, weight: 7)
        t.run(args: ["balance-sizes"], env: CommandEnv(workspace: "a"))
        #expect(root.children.allSatisfy { $0.getWeight(.h) == 1 })
        #expect(column.children.allSatisfy { $0.getWeight(.v) == 1 })
    }

    @Test func close() {
        let root = t.workspace("a").rootTilingContainer
        t.focus(t.window(1, in: root))
        t.window(2, in: root)
        t.run("close")
        #expect(t.focusedWindowId == 2)
        #expect(root.children.count == 1)
        #expect(t.platform.closed == [1])
    }

    @Test func closeViaWindowIdFlag() {
        let root = t.workspace("a").rootTilingContainer
        t.focus(t.window(1, in: root))
        t.window(2, in: root)
        t.run("close --window-id 2")
        #expect(t.focusedWindowId == 1)
        #expect(root.children.count == 1)
        #expect(t.run("close --window-id 2").stderr == "Invalid <window-id> 2 passed to --window-id")
    }

    @Test func closeQuitsTheAppForItsLastWindow() {
        let root = t.workspace("a").rootTilingContainer
        t.focus(t.window(1, in: root, pid: 42))
        t.window(2, in: root, pid: 7)
        t.run("close --quit-if-last-window")
        #expect(t.platform.terminated == [42])
        #expect(t.world.window(byId: 1) == nil)
        t.platform.terminateSucceeds = false
        t.focus(t.world.window(byId: 2)!)
        let result = t.run("close --quit-if-last-window")
        #expect(result.exitCode == 2)
        #expect(result.stderr == "Failed to quit 'bobko.AeroSpace.test-app'")
    }

    @Test func closeAllWindowsButCurrent() {
        let workspace = t.workspace("a")
        let root = workspace.rootTilingContainer
        t.window(1, in: root)
        t.focus(t.window(2, in: root))
        t.window(3, in: t.vTiles(root))
        t.window(4, in: workspace.floatingWindowsContainer)
        t.window(5, in: t.workspace("b").rootTilingContainer)
        #expect(t.run("close-all-windows-but-current").exitCode == 0)
        #expect(t.platform.closed.sorted() == [1, 3, 4])
        #expect(workspace.allLeafWindowsRecursive.map(\.id) == [2])
        #expect(t.world.window(byId: 5) != nil)
        #expect(t.focusedWindowId == 2)

        t.world.focusWorkspace(t.workspace("empty"))
        #expect(t.run("close-all-windows-but-current").stderr == "Empty workspace")
    }
}
