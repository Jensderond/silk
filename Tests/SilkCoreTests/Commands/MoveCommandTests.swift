import CoreGraphics
import Testing
@testable import SilkCore

@Suite struct MoveCommandTests {
    let t = TestHarness()

    @Test func parse() {
        #expect(parseScript("move --fail-if-fullscreen left").errorOrNil == nil)
        #expect(parseScript("move --fail-if-macos-native-fullscreen --window-id 1 right").errorOrNil == nil)
    }

    @Test func failIfFullscreen() {
        let root = t.workspace("a").rootTilingContainer
        let window = t.window(1, in: root)
        #expect(t.focus(window))
        window.isFullscreen = true
        t.window(2, in: root)
        #expect(t.run("move --fail-if-fullscreen right").exitCode == 2)
        #expect(root.layoutDescription == .h_tiles([.window(1), .window(2)]))
    }

    @Test func failIfMacosNativeFullscreen() {
        let root = t.workspace("a").rootTilingContainer
        let window = t.window(1, in: root)
        #expect(t.focus(window))
        window.isMacosFullscreen = true
        t.window(2, in: root)
        let result = t.run("move --fail-if-macos-native-fullscreen right")
        #expect(result.exitCode == 2)
    }

    @Test func failIfFullscreenAllowsRegularWindows() {
        let root = t.workspace("a").rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        #expect(t.run("move --fail-if-fullscreen --fail-if-macos-native-fullscreen right").exitCode == 0)
        #expect(root.layoutDescription == .h_tiles([.window(2), .window(1)]))
    }

    @Test func swapWindows() {
        let root = t.workspace("a").rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        t.run("move right")
        #expect(root.layoutDescription == .h_tiles([.window(2), .window(1)]))
    }

    @Test func moveIntoTopMostContainerWithRightOrientation() {
        let root = t.workspace("a").rootTilingContainer
        t.window(0, in: root)
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: t.hTiles(t.hTiles(root)))
        t.run("move right")
        #expect(root.layoutDescription == .h_tiles([.window(0), .h_tiles([.window(1), .h_tiles([.window(2)])])]))
    }

    @Test func moveMru() {
        let root = t.workspace("a").rootTilingContainer
        t.window(0, in: root)
        #expect(t.focus(t.window(1, in: root)))
        let column = t.vTiles(root)
        let row = t.hTiles(column)
        t.window(2, in: row)
        let window3 = t.window(3, in: row)
        t.window(4, in: column)
        window3.markAsMostRecentChild()

        t.run("move right")
        #expect(root.layoutDescription == .h_tiles([
            .window(0),
            .v_tiles([.h_tiles([.window(1), .window(2), .window(3)]), .window(4)]),
        ]))
    }

    @Test func swapKeepsWeights() {
        let root = t.workspace("a").rootTilingContainer
        let window1 = t.window(1, in: root, weight: 1)
        let window2 = t.window(2, in: root, weight: 2)
        t.focus(window2)
        t.run("move left")
        #expect(window2.hWeight == 2)
        #expect(window1.hWeight == 1)
    }

    @Test func moveInGetsNewWeight() {
        let root = t.workspace("a").rootTilingContainer
        t.window(0, in: root, weight: 1)
        let window1 = t.window(1, in: root, weight: 2)
        let window2 = t.window(2, in: t.vTiles(root), weight: 1)
        t.focus(window1)
        t.run("move right")
        #expect(window2.hWeight == 1)
        #expect(window2.vWeight == 1)
        #expect(window1.vWeight == 1)
        #expect(window1.hWeight == 1)
    }

    @Test func createImplicitContainer() {
        let workspace = t.workspace("a")
        let root = workspace.rootTilingContainer
        t.window(1, in: root)
        #expect(t.focus(t.window(2, in: root)))
        t.window(3, in: root)
        #expect(t.run("move up").exitCode == 0)
        #expect(workspace.layoutDescription == .workspace([.v_tiles([.window(2), .h_tiles([.window(1), .window(3)])])]))
    }

    @Test func stopOnRootNode() {
        let workspace = t.workspace("a")
        let root = workspace.rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        t.window(3, in: root)
        #expect(t.run("move --boundaries-action stop left").exitCode == 0)
        #expect(workspace.layoutDescription == .workspace([.h_tiles([.window(1), .window(2), .window(3)])]))
        #expect(t.run("move --boundaries-action stop up").exitCode == 0)
        #expect(workspace.layoutDescription == .workspace([.h_tiles([.window(1), .window(2), .window(3)])]))
    }

    @Test func stopOnRootNodeWhenNoBoundary() {
        let workspace = t.workspace("a")
        let root = workspace.rootTilingContainer
        t.window(1, in: root)
        #expect(t.focus(t.window(2, in: root)))
        t.window(3, in: root)
        #expect(t.run("move --boundaries-action stop left").exitCode == 0)
        #expect(workspace.layoutDescription == .workspace([.h_tiles([.window(2), .window(1), .window(3)])]))
    }

    @Test func stopOnInnerNode() {
        let workspace = t.workspace("a")
        let root = workspace.rootTilingContainer
        t.window(1, in: root)
        let column = t.vTiles(root)
        #expect(t.focus(t.window(2, in: column)))
        t.window(3, in: column)
        #expect(t.run("move --boundaries-action stop right").exitCode == 0)
        #expect(workspace.layoutDescription == .workspace([.h_tiles([.window(1), .v_tiles([.window(3)]), .window(2)])]))
    }

    @Test func fail() {
        let workspace = t.workspace("a")
        let root = workspace.rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        t.window(3, in: root)
        #expect(t.run("move --boundaries-action fail left").exitCode == 2)
        #expect(workspace.layoutDescription == .workspace([.h_tiles([.window(1), .window(2), .window(3)])]))
    }

    @Test func moveOut() {
        let root = t.workspace("a").rootTilingContainer
        t.window(1, in: root)
        let column = t.vTiles(root)
        #expect(t.focus(t.window(2, in: column)))
        t.window(3, in: column)
        t.window(4, in: column)
        t.run("move left")
        #expect(root.layoutDescription == .h_tiles([.window(1), .window(2), .v_tiles([.window(3), .window(4)])]))
    }

    @Test func moveOutWithNormalization() {
        let t = TestHarness(config: testConfig { $0.enableNormalizationFlattenContainers = true })
        let workspace = t.workspace("a")
        t.window(1, in: workspace.rootTilingContainer)
        #expect(t.focus(t.window(2, in: workspace.rootTilingContainer)))
        t.run("move right")
        #expect(workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(1), .window(2)]))
        #expect(t.focusedWindowId == 2)

        t.focus(t.world.window(byId: 1)!)
        t.run("move left")
        #expect(workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(1), .window(2)]))
        #expect(t.focusedWindowId == 1)
    }

    @Test func floatingAndUnconventionalWindowsCantMove() {
        let workspace = t.workspace("a")
        let floating = t.window(1, in: workspace.floatingWindowsContainer)
        t.focus(floating)
        let result = t.run("move left")
        #expect(result.exitCode == 2)
        #expect(result.stderr == "moving floating windows isn't yet supported")
    }

    @Test func allMonitorsOuterFrameMovesToTheNeighbourMonitor() {
        let left = Monitor(id: "L", name: "Left", frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), isMain: true)
        let right = Monitor(id: "R", name: "Right", frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800), isMain: false)
        let t = TestHarness(monitors: [left, right])
        let leftWorkspace = t.world.activeWorkspace(on: left)
        let rightWorkspace = t.world.activeWorkspace(on: right)
        let window = t.window(1, in: leftWorkspace.rootTilingContainer)
        t.window(2, in: rightWorkspace.rootTilingContainer)
        t.focus(window)
        #expect(t.run("move --boundaries all-monitors-outer-frame right").exitCode == 0)
        #expect(rightWorkspace.rootTilingContainer.layoutDescription == .h_tiles([.window(1), .window(2)]))
        #expect(t.focusedWindowId == 1)
        #expect(t.world.focus.workspace === rightWorkspace)
    }
}
