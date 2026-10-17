import CoreGraphics
import SilkConfig
import Testing
@testable import SilkCore

@Suite struct LayoutCommandTests {
    let t = TestHarness()

    @Test func parse() {
        #expect(parseScript("layout v_tiles h_tiles").errorOrNil == nil)
        #expect(parseScript("layout tiling").errorOrNil == nil)
        #expect(parseScript("layout floating tiling").errorOrNil == nil)
        #expect(parseScript("layout --window-id 1 horizontal vertical").errorOrNil == nil)
        #expect(parseScript("layout --root accordion tiling").errorOrNil == "layout command: --root and tiling|floating are incompatible")
        let root = parseSingle("layout --root accordion tiles", as: LayoutCommand.self)
        #expect(root?.toggleBetween == [.accordion, .tiles])
        #expect(root?.root == true)
        #expect(parseScript("layout list").errorOrNil == nil)
        #expect(parseScript("layout --workspace 2 tiles").errorOrNil == "--workspace flag requires using an explicit --root flag")
        #expect(parseScript("layout --workspace 2 --window-id 2 tiles").errorOrNil == "ERROR: Conflicting options: --window-id, --workspace")
        #expect(parseScript("layout --fail-if-noop accordion tiling").errorOrNil == "--fail-if-noop allows only one <target-layout> argument")
        #expect(parseSingle("layout --for-next-detected-window floating", as: LayoutCommand.self)?.forNextDetectedWindow == true)
        let forNextError = "layout command: --for-next-detected-window allows only one tiling|floating <target-layout> argument"
        #expect(parseScript("layout --for-next-detected-window floating tiling").errorOrNil == forNextError)
        #expect(parseScript("layout --for-next-detected-window accordion").errorOrNil == forNextError)
        #expect(parseScript("layout --for-next-detected-window --window-id 1 floating").errorOrNil == "ERROR: Conflicting options: --for-next-detected-window, --window-id")
        #expect(parseScript("layout --for-next-detected-window --workspace 2 floating").errorOrNil == "ERROR: Conflicting options: --for-next-detected-window, --workspace")
        #expect(parseScript("layout --for-next-detected-window --root floating").errorOrNil == "ERROR: Conflicting options: --for-next-detected-window, --root")
        #expect(parseScript("layout --for-next-detected-window --fail-if-noop floating").errorOrNil == "ERROR: Conflicting options: --fail-if-noop, --for-next-detected-window")
        #expect(parseScript("layout foo").errorOrNil == "ERROR: Can't parse 'foo'\n       Possible values: (accordion|tiles|horizontal|vertical|h_accordion|v_accordion|h_tiles|v_tiles|tiling|floating)")
    }

    @Test func forNextDetectedWindowDoesNotTouchExistingWindows() {
        let workspace = t.workspace("a")
        #expect(t.focus(t.window(1, in: workspace.rootTilingContainer)))
        #expect(t.run("layout floating --for-next-detected-window").exitCode == 0)
        #expect(workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(1)]))
        #expect(workspace.floatingWindows.isEmpty)
    }

    @Test func forNextDetectedWindowAppliesOnceToTheNextDetectedWindow() {
        let workspace = t.workspace("a")
        let root = workspace.rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.run("layout floating --for-next-detected-window")
        t.world.runOnWindowDetected(ifConventional: t.window(2, in: root))
        t.world.runOnWindowDetected(ifConventional: t.window(3, in: root))
        #expect(workspace.floatingWindows.map(\.id) == [2])
        #expect(root.layoutDescription == .h_tiles([.window(1), .window(3)]))
    }

    @Test func forNextDetectedWindowSecondInvocationReplacesTheScheduledLayout() {
        let workspace = t.workspace("a")
        let root = workspace.rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.run("layout floating --for-next-detected-window")
        t.run("layout tiling --for-next-detected-window")
        t.world.runOnWindowDetected(ifConventional: t.window(2, in: workspace.floatingWindowsContainer))
        #expect(workspace.floatingWindows.isEmpty)
        #expect(root.layoutDescription == .h_tiles([.window(1), .window(2)]))
    }

    @Test func forNextDetectedWindowAppliedBeforeAndAfterOnWindowDetectedCallbacks() {
        var rule = WindowDetectedRule()
        rule.run = CommandScripts(["layout floating tiling"])
        let t = TestHarness(config: testConfig { $0.onWindowDetected = [rule] })
        let workspace = t.workspace("a")
        let root = workspace.rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.run("layout floating --for-next-detected-window")
        t.world.runOnWindowDetected(ifConventional: t.window(2, in: root))
        #expect(workspace.floatingWindows.map(\.id) == [2])
        #expect(root.layoutDescription == .h_tiles([.window(1)]))
    }

    @Test func changeOrientationAndLayout() {
        let root = t.workspace("a").rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        t.run("layout vertical")
        #expect(root.layoutDescription == .v_tiles([.window(1), .window(2)]))
        t.run("layout accordion")
        #expect(root.layoutDescription == .v_accordion([.window(1), .window(2)]))
        t.run("layout h_tiles")
        #expect(root.layoutDescription == .h_tiles([.window(1), .window(2)]))
        t.run("layout v_accordion")
        #expect(root.layoutDescription == .v_accordion([.window(1), .window(2)]))
    }

    @Test func toggleBetweenSkipsMatching() {
        let root = t.workspace("a").rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        t.run("layout h_tiles h_accordion")
        #expect(root.layout == .accordion)
        #expect(root.orientation == .h)
        // The user's `alt-slash` / `alt-comma` bindings
        t.run("layout tiles horizontal vertical")
        #expect(root.layoutDescription == .h_tiles([.window(1), .window(2)]))
        t.run("layout tiles horizontal vertical")
        #expect(root.layoutDescription == .v_tiles([.window(1), .window(2)]))
        t.run("layout accordion horizontal vertical")
        #expect(root.layoutDescription == .v_accordion([.window(1), .window(2)]))
        t.run("layout accordion horizontal vertical")
        #expect(root.layoutDescription == .h_accordion([.window(1), .window(2)]))
    }

    @Test func allMatchingIsANoopWithATip() {
        let root = t.workspace("a").rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        let result = t.run("layout h_tiles")
        #expect(result.exitCode == 0)
        #expect(result.stderr == "Already in the requested h_tiles mode. Tip: use --fail-if-noop to exit with non-zero exit code")
        #expect(t.run("layout --fail-if-noop h_tiles").exitCode == 2)
    }

    @Test func emptyWorkspace() {
        let workspace = t.workspace("a")
        t.world.focusWorkspace(workspace) // Unfocused empty workspaces are garbage collected before commands run
        let env = CommandEnv(workspace: "a")
        #expect(t.run(args: ["layout", "v_tiles"], env: env).exitCode == 0)
        #expect(workspace.rootTilingContainer.orientation == .v)
        #expect(t.run(args: ["layout", "accordion"], env: env).exitCode == 0)
        #expect(workspace.rootTilingContainer.layout == .accordion)

        let floating = t.run(args: ["layout", "floating"], env: env)
        #expect(floating.exitCode == 2)
        #expect(floating.stderr == noWindowIsFocused)
        let tiling = t.run(args: ["layout", "tiling"], env: env)
        #expect(tiling.exitCode == 0)
        #expect(tiling.stderr == "Already in the requested tiling mode. Tip: use --fail-if-noop to exit with non-zero exit code")
        let tilingNoop = t.run(args: ["layout", "tiling", "--fail-if-noop"], env: env)
        #expect(tilingNoop.exitCode == 2)
        #expect(tilingNoop.stderr == "")
    }

    @Test func tilingToFloatingAndBack() {
        let workspace = t.workspace("a")
        let root = workspace.rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        t.run("layout floating")
        #expect(root.layoutDescription == .h_tiles([.window(2)]))
        #expect(workspace.floatingWindows.map(\.id) == [1])
        #expect(t.focusedWindowId == 1)

        t.run("layout tiling")
        #expect(workspace.floatingWindows.isEmpty)
        #expect(root.layoutDescription == .h_tiles([.window(2), .window(1)]))
    }

    @Test func togglesAcrossFloatingAndTiling() {
        let workspace = t.workspace("a")
        #expect(t.focus(t.window(1, in: workspace.floatingWindowsContainer)))
        // The user's service-mode `f` binding
        t.run("layout floating tiling")
        #expect(workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(1)]))
        t.run("layout floating tiling")
        #expect(workspace.floatingWindows.map(\.id) == [1])
    }

    @Test func floatingRestoresLastFloatingSize() {
        let workspace = t.workspace("a")
        let window = t.window(1, in: workspace.rootTilingContainer, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.lastFloatingSize = CGSize(width: 640, height: 480)
        t.focus(window)
        t.run("layout floating")
        #expect(window.lastKnownFrame == CGRect(x: 0, y: 0, width: 640, height: 480))
        window.lastKnownFrame = CGRect(x: 10, y: 10, width: 700, height: 500)
        t.run("layout tiling")
        #expect(window.lastFloatingSize == CGSize(width: 700, height: 500))
    }

    @Test func tilingLayoutOnFloatingWindowFails() {
        let workspace = t.workspace("a")
        #expect(t.focus(t.window(1, in: workspace.floatingWindowsContainer)))
        let result = t.run("layout v_tiles")
        #expect(result.exitCode == 2)
        #expect(result.stderr == "The window is non-tiling")
        #expect(t.run("layout floating").exitCode == 0)
        #expect(workspace.floatingWindows.map(\.id) == [1])
    }

    @Test func rootChangesRootInsteadOfNestedParent() {
        let root = t.workspace("a").rootTilingContainer
        #expect(t.focus(t.window(1, in: t.vTiles(root))))
        t.window(2, in: root)
        t.run("layout --root v_accordion")
        #expect(root.layoutDescription == .v_accordion([.v_tiles([.window(1)]), .window(2)]))
    }

    @Test func rootWithFloatingOrFullscreenFocusedWindowChangesRootContainer() {
        let workspace = t.workspace("a")
        #expect(t.focus(t.window(1, in: workspace.floatingWindowsContainer)))
        t.run("layout --root v_accordion")
        #expect(workspace.rootTilingContainer.layout == .accordion)
        #expect(workspace.rootTilingContainer.orientation == .v)

        let other = t.workspace("b")
        #expect(t.focus(t.window(2, in: other.macosFullscreenWindowsContainer)))
        #expect(t.run("layout v_accordion").stderr == "Can't change layout for macOS minimized, fullscreen windows or windows or hidden apps. This behavior is subject to change")
        t.run("layout --root v_accordion")
        #expect(other.rootTilingContainer.layout == .accordion)
    }

    @Test func rootWithWindowIdOrWorkspaceTargetsThatWorkspace() {
        let focusedRoot = t.workspace("a").rootTilingContainer
        #expect(t.focus(t.window(1, in: focusedRoot)))
        let otherRoot = t.workspace("b").rootTilingContainer
        t.window(2, in: otherRoot)
        t.run("layout --root --window-id 2 v_accordion")
        #expect(otherRoot.layout == .accordion)
        #expect(otherRoot.orientation == .v)
        #expect(focusedRoot.layout == .tiles)

        let third = t.workspace("c").rootTilingContainer
        t.window(3, in: third)
        t.run("layout --root --workspace c v_accordion")
        #expect(third.layout == .accordion)
        #expect(focusedRoot.layout == .tiles)
    }

    @Test func oppositeOrientationNormalizationAlternatesAncestors() {
        let t = TestHarness(config: testConfig { $0.enableNormalizationOppositeOrientationForNestedContainers = true })
        let root = t.workspace("a").rootTilingContainer
        t.window(1, in: root)
        let column = t.vTiles(root)
        #expect(t.focus(t.window(2, in: column)))
        t.window(3, in: column)
        t.run("layout horizontal")
        #expect(root.layoutDescription == .v_tiles([.window(1), .h_tiles([.window(2), .window(3)])]))
    }
}
