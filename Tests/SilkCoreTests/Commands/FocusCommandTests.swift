import CoreGraphics
import Testing
@testable import SilkCore

@Suite struct FocusCommandTests {
    let t = TestHarness()

    @Test func parse() {
        #expect(parseScript("focus --boundaries left").errorOrNil?.contains("Possible values") == true)
        let parsed = parseSingle("focus --boundaries workspace left", as: FocusCommand.self)
        #expect(parsed?.rawBoundaries == .workspace)
        #expect(parsed?.cardinalOrDfsDirection == .direction(.left))
        #expect(parseScript("focus --boundaries workspace --boundaries workspace left").errorOrNil == "ERROR: Duplicated option '--boundaries'")
        #expect(parseScript("focus --window-id 42 --ignore-floating").errorOrNil == "--window-id is incompatible with other options")
        #expect(parseScript("focus --boundaries all-monitors-outer-frame dfs-next").errorOrNil == "(dfs-next|dfs-prev) only supports --boundaries workspace")
        #expect(parseScript("focus --window-id 42 --wrap-around").errorOrNil == "--window-id is incompatible with other options")
        #expect(parseScript("focus left --boundaries-action wrap-around-the-workspace --wrap-around").errorOrNil == "ERROR: Conflicting options: --boundaries-action, --wrap-around")
        #expect(parseScript("focus dfs-next --fail-if-fullscreen").errorOrNil == "--fail-if-fullscreen/--fail-if-macos-native-fullscreen require using (left|down|up|right) argument")
        #expect(parseScript("focus --fail-if-macos-native-fullscreen --window-id 42").errorOrNil == "--window-id is incompatible with other options")
        #expect(parseScript("focus --fail-if-fullscreen --fail-if-macos-native-fullscreen left").errorOrNil == nil)
        #expect(parseScript("focus --window-id 42").errorOrNil == nil)
        #expect(parseScript("focus --dfs-index 1 left").errorOrNil == "--dfs-index is incompatible with other options")
        #expect(parseScript("focus").errorOrNil == "Mandatory argument is missing. (left|down|up|right|dfs-next|dfs-prev), --window-id or --dfs-index is required")
        #expect(parseScript("focus --boundaries-action wrap-around-all-monitors left").errorOrNil == "workspace and wrap-around-all-monitors is an invalid combination of values")
    }

    @Test func failIfFullscreen() {
        let root = t.workspace("a").rootTilingContainer
        let window = t.window(1, in: root)
        #expect(t.focus(window))
        window.isFullscreen = true
        t.window(2, in: root)
        #expect(t.run("focus --fail-if-fullscreen right").exitCode == 2)
        #expect(t.focusedWindowId == 1)
    }

    @Test func failIfMacosNativeFullscreen() {
        let root = t.workspace("a").rootTilingContainer
        let window = t.window(1, in: root)
        #expect(t.focus(window))
        window.isMacosFullscreen = true
        t.window(2, in: root)
        #expect(t.run("focus --fail-if-macos-native-fullscreen right").exitCode == 2)
    }

    @Test func failIfFullscreenAllowsRegularWindows() {
        let root = t.workspace("a").rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        #expect(t.run("focus --fail-if-fullscreen --fail-if-macos-native-fullscreen right").exitCode == 0)
        #expect(t.focusedWindowId == 2)
    }

    @Test func focusSetsFocus() {
        #expect(t.focusedWindowId == nil)
        let root = t.workspace("a").rootTilingContainer
        t.window(1, in: root)
        #expect(t.focus(t.window(2, in: root)))
        t.window(3, in: root)
        #expect(t.focusedWindowId == 2)
    }

    @Test func focusOverFloatingWindows() {
        let floating = t.workspace("a").floatingWindowsContainer
        t.window(1, in: floating, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(t.focus(t.window(2, in: floating, frame: CGRect(x: 10, y: 10, width: 100, height: 100))))
        t.window(3, in: floating, frame: CGRect(x: 20, y: 20, width: 100, height: 100))
        #expect(t.focusedWindowId == 2)
        t.run("focus right")
        #expect(t.focusedWindowId == 3)
        // Floating windows are restored after the command
        #expect(t.workspace("a").floatingWindows.map(\.id).sorted() == [1, 2, 3])
    }

    @Test func ignoreFloating() {
        let workspace = t.workspace("a")
        #expect(t.focus(t.window(1, in: workspace.rootTilingContainer)))
        t.window(2, in: workspace.floatingWindowsContainer, frame: CGRect(x: 1500, y: 10, width: 100, height: 100))
        _ = t.manager.computeLayout()
        t.run("focus --ignore-floating right")
        #expect(t.focusedWindowId == 1)
        t.run("focus right")
        #expect(t.focusedWindowId == 2)
    }

    @Test func focusAlongTheContainerOrientation() {
        let root = t.workspace("a").rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        t.run("focus right")
        #expect(t.focusedWindowId == 2)
    }

    @Test func focusAcrossTheContainerOrientation() {
        let workspace = t.workspace("a")
        t.window(1, in: workspace.rootTilingContainer)
        t.window(2, in: workspace.rootTilingContainer)
        #expect(t.world.focusWorkspace(workspace))
        #expect(t.focusedWindowId == 2)
        t.run("focus up")
        #expect(t.focusedWindowId == 2)
        t.run("focus down")
        #expect(t.focusedWindowId == 2)
    }

    @Test func focusNoWrapping() {
        let root = t.workspace("a").rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        t.run("focus left")
        #expect(t.focusedWindowId == 1)
    }

    @Test func focusWrapping() {
        let root = t.workspace("a").rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        t.run("focus --boundaries workspace --boundaries-action wrap-around-the-workspace left")
        #expect(t.focusedWindowId == 2)
        t.run("focus --wrap-around right")
        #expect(t.focusedWindowId == 1)
    }

    @Test func focusFindsMruLeaf() {
        let workspace = t.workspace("a")
        let root = workspace.rootTilingContainer
        let start = t.window(1, in: root)
        let column = t.vTiles(root)
        let row = t.hTiles(column)
        let window2 = t.window(2, in: row)
        let unrelated = t.window(5, in: row)
        let window3 = t.window(3, in: column)

        #expect(workspace.mostRecentWindowRecursive?.id == 3) // The latest bound
        t.focus(start)
        t.run("focus right")
        #expect(t.focusedWindowId == 3)

        window2.markAsMostRecentChild()
        t.focus(start)
        t.run("focus right")
        #expect(t.focusedWindowId == 2)

        window3.markAsMostRecentChild()
        unrelated.markAsMostRecentChild()
        t.focus(start)
        t.run("focus right")
        #expect(t.focusedWindowId == 2)
    }

    @Test func focusOutsideOfTheContainer() {
        let root = t.workspace("a").rootTilingContainer
        t.window(1, in: root)
        #expect(t.focus(t.window(2, in: t.vTiles(root))))
        t.run("focus left")
        #expect(t.focusedWindowId == 1)
    }

    @Test func focusOutsideOfTheContainer2() {
        let root = t.workspace("a").rootTilingContainer
        t.window(1, in: root)
        #expect(t.focus(t.window(2, in: t.hTiles(root))))
        t.run("focus left")
        #expect(t.focusedWindowId == 1)
    }

    @Test func focusDfsRelative() {
        let root = t.workspace("a").rootTilingContainer
        let column = t.vTiles(root)
        #expect(t.focus(t.window(1, in: column)))
        let row = t.hTiles(column)
        t.window(2, in: row)
        t.window(3, in: row)
        t.window(4, in: root)
        for expected: WindowID in [2, 3, 4] {
            t.run("focus dfs-next")
            #expect(t.focusedWindowId == expected)
        }
        for expected: WindowID in [3, 2, 1] {
            t.run("focus dfs-prev")
            #expect(t.focusedWindowId == expected)
        }
    }

    @Test func focusDfsRelativeWrapping() {
        let root = t.workspace("a").rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        #expect(t.run("focus --boundaries-action stop dfs-prev").exitCode == 0)
        #expect(t.focusedWindowId == 1)
        #expect(t.run("focus --boundaries-action fail dfs-prev").exitCode == 2)
        #expect(t.focusedWindowId == 1)
        #expect(t.run("focus --boundaries-action wrap-around-the-workspace dfs-prev").exitCode == 0)
        #expect(t.focusedWindowId == 2)
        #expect(t.run("focus --boundaries-action stop dfs-next").exitCode == 0)
        #expect(t.focusedWindowId == 2)
        #expect(t.run("focus --boundaries-action fail dfs-next").exitCode == 2)
        #expect(t.focusedWindowId == 2)
        #expect(t.run("focus --boundaries-action wrap-around-the-workspace dfs-next").exitCode == 0)
        #expect(t.focusedWindowId == 1)
    }

    @Test func focusByWindowIdAndDfsIndex() {
        let workspace = t.workspace("a")
        t.window(1, in: workspace.rootTilingContainer)
        t.window(2, in: workspace.rootTilingContainer)
        t.focus(t.window(3, in: t.workspace("b").rootTilingContainer))
        #expect(t.run("focus --window-id 1").exitCode == 0)
        #expect(t.focusedWindowId == 1)
        #expect(t.run("focus --dfs-index 1").exitCode == 0)
        #expect(t.focusedWindowId == 2)
        let missing = t.run("focus --window-id 99")
        #expect(missing.exitCode == 2)
        #expect(missing.stderr == "Invalid <window-id> 99 passed to --window-id")
        #expect(t.run("focus --dfs-index 5").stderr == "Can't find window with DFS index 5")
    }

    @Test func focusingAWindowAsksMacosToFocusIt() {
        let root = t.workspace("a").rootTilingContainer
        t.focus(t.window(1, in: root))
        t.window(2, in: root)
        t.platform.focused = []
        t.run("focus right")
        #expect(t.platform.focused == [2])
    }

    @Test func allMonitorsOuterFrameCrossesMonitors() {
        let left = Monitor(id: "L", name: "Left", frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), isMain: true)
        let right = Monitor(id: "R", name: "Right", frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800), isMain: false)
        let t = TestHarness(monitors: [left, right])
        let leftWorkspace = t.world.activeWorkspace(on: left)
        let rightWorkspace = t.world.activeWorkspace(on: right)
        t.focus(t.window(1, in: leftWorkspace.rootTilingContainer))
        t.window(2, in: rightWorkspace.rootTilingContainer)
        t.run("focus --boundaries all-monitors-outer-frame right")
        #expect(t.focusedWindowId == 2)
        #expect(t.run("focus --boundaries all-monitors-outer-frame right").exitCode == 0)
        #expect(t.focusedWindowId == 2)
        t.run("focus --boundaries all-monitors-outer-frame --boundaries-action wrap-around-all-monitors right")
        #expect(t.focusedWindowId == 1)
    }
}
