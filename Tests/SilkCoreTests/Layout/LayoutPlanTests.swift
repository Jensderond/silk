import CoreGraphics
import SilkConfig
import Testing
@testable import SilkCore

private func monitor(_ id: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, name: String? = nil, isMain: Bool = false) -> Monitor {
    let frame = CGRect(x: x, y: y, width: width, height: height)
    return Monitor(id: id, name: name ?? id, frame: frame, visibleFrame: frame, isMain: isMain)
}

@Suite struct LayoutMathTests {
    @Test func tilesWithWeightsAndGaps() {
        let t = TestHarness(config: testConfig {
            $0.gaps.inner.horizontal = .constant(10)
            $0.gaps.inner.vertical = .constant(6)
            $0.gaps.outer.left = .constant(20)
            $0.gaps.outer.right = .constant(20)
            $0.gaps.outer.top = .constant(5)
            $0.gaps.outer.bottom = .constant(5)
        })
        let workspace = t.workspace("1")
        let root = workspace.rootTilingContainer
        t.window(1, in: root, weight: 1)
        let column = t.vTiles(root, weight: 2)
        t.window(2, in: column)
        t.window(3, in: column)
        t.world.focusWorkspace(workspace)
        let plan = t.manager.computeLayout()
        // Usable: x 20...1900 (1880 wide), y 5...1074 (1069 high after the `- 1`). Layout adds the same delta to every
        // weight so they sum up to the available size: 1 + 938.5 and 2 + 938.5.
        #expect(root.children[0].hWeight == 939.5)
        #expect(column.hWeight == 940.5)
        #expect(plan.frames[1] == CGRect(x: 20, y: 5, width: 934.5, height: 1069))
        #expect(plan.frames[2] == CGRect(x: 964.5, y: 5, width: 935.5, height: 531.5))
        #expect(plan.frames[3] == CGRect(x: 964.5, y: 542.5, width: 935.5, height: 531.5))
        #expect(plan.focusedWindow == 3)
    }

    @Test func perMonitorGaps() {
        let main = monitor("main", 0, 0, 1000, 800, name: "DELL", isMain: true)
        let laptop = monitor("laptop", 1000, 0, 1000, 800, name: "Built-in Retina Display")
        let t = TestHarness(config: testConfig {
            $0.gaps.outer.left = .perMonitor([PerMonitorValue(monitor: .nameRegex("built-in"), value: 50), PerMonitorValue(monitor: .main, value: 10)], default: 0)
        }, monitors: [main, laptop])
        t.window(1, in: t.world.activeWorkspace(on: main).rootTilingContainer)
        t.window(2, in: t.world.activeWorkspace(on: laptop).rootTilingContainer)
        let plan = t.manager.computeLayout()
        #expect(plan.frames[1] == CGRect(x: 10, y: 0, width: 990, height: 799))
        #expect(plan.frames[2] == CGRect(x: 1050, y: 0, width: 950, height: 799))
    }

    @Test func accordion() {
        let t = TestHarness(config: testConfig { $0.accordionPadding = 30 })
        let workspace = t.workspace("1")
        let root = workspace.rootTilingContainer
        root.layout = .accordion
        for id: WindowID in 1 ... 4 { t.window(id, in: root) }
        t.focus(t.world.window(byId: 2)!)
        let plan = t.manager.computeLayout()
        #expect(plan.frames[1] == CGRect(x: 0, y: 0, width: 1920 - 30, height: 1079))
        #expect(plan.frames[2] == CGRect(x: 30, y: 0, width: 1920 - 60, height: 1079))
        #expect(plan.frames[3] == CGRect(x: 60, y: 0, width: 1920 - 60, height: 1079))
        #expect(plan.frames[4] == CGRect(x: 30, y: 0, width: 1920 - 30, height: 1079))
        t.world.window(byId: 2)!.unbindFromParent()
        t.world.window(byId: 3)!.unbindFromParent()
        t.world.window(byId: 4)!.unbindFromParent()
        #expect(t.manager.computeLayout().frames[1] == CGRect(x: 0, y: 0, width: 1920, height: 1079))
    }

    @Test func fullscreen() {
        let t = TestHarness(config: testConfig { $0.gaps.outer.top = .constant(10) })
        let root = t.workspace("1").rootTilingContainer
        t.window(1, in: root)
        let window2 = t.window(2, in: root)
        t.focus(window2)
        t.run("fullscreen")
        #expect(t.manager.computeLayout().frames[2] == CGRect(x: 0, y: 10, width: 1920, height: 1070))
        #expect(t.run("fullscreen on") == CommandResult(exitCode: 0, stderr: "Already fullscreen. Tip: use --fail-if-noop to exit with non-zero code"))
        t.run("fullscreen off")
        t.run("fullscreen on --no-outer-gaps")
        #expect(t.manager.computeLayout().frames[2] == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(t.manager.menuBarModel().text == "[1]")
        // Fullscreen ends when another window becomes the most recent one
        t.focus(t.world.window(byId: 1)!)
        _ = t.manager.computeLayout()
        #expect(!window2.isFullscreen)
        #expect(parseScript("fullscreen off --no-outer-gaps").errorOrNil == "--no-outer-gaps is incompatible with 'off' argument")
        #expect(parseScript("fullscreen --fail-if-noop").errorOrNil == "--fail-if-noop requires 'on' or 'off' argument")
    }

    @Test func floatingWindowsMoveProportionallyWithTheirWorkspace() {
        let left = monitor("L", 0, 0, 1000, 1000, isMain: true)
        let right = monitor("R", 1000, 0, 2000, 1000)
        let t = TestHarness(monitors: [left, right])
        let workspace = t.world.activeWorkspace(on: left)
        let window = t.window(1, in: workspace.floatingWindowsContainer, frame: CGRect(x: 100, y: 200, width: 300, height: 300))
        t.focus(window)
        #expect(t.manager.computeLayout().frames[1] == CGRect(x: 100, y: 200, width: 300, height: 300))
        t.run("move-workspace-to-monitor right")
        #expect(t.manager.computeLayout().frames[1] == CGRect(x: 1200, y: 200, width: 300, height: 300))
        #expect(window.lastKnownFrame == CGRect(x: 1200, y: 200, width: 300, height: 300))
    }

    @Test func gapsLargerThanTheMonitorClampToZero() {
        let t = TestHarness(config: testConfig { $0.gaps.outer.left = .constant(5000) })
        t.window(1, in: t.workspace("1").rootTilingContainer)
        #expect(t.manager.computeLayout().frames[1]?.width == 0)
    }
}

@Suite struct HidingTests {
    @Test(arguments: [
        // Laptop right of the main monitor, bottoms aligned: the main monitor hides bottom left, the laptop bottom right
        ([monitor("M", 0, 0, 2560, 1440, isMain: true), monitor("B", 2560, 458, 1512, 982)], [HideCorner.bottomLeft, .bottomRight]),
        // Single monitor
        ([monitor("M", 0, 0, 1920, 1080, isMain: true)], [.bottomRight]),
        // Monitor left of the main one
        ([monitor("M", 0, 0, 1920, 1080, isMain: true), monitor("L", -1920, 0, 1920, 1080)], [.bottomRight, .bottomLeft]),
    ])
    func optimalHideCorner(monitors: [Monitor], expected: [HideCorner]) {
        let t = TestHarness(monitors: monitors)
        #expect(monitors.map(t.world.optimalHideCorner) == expected)
    }

    @Test func hiddenWindowsAndUnhiding() {
        let main = monitor("M", 0, 0, 2000, 1000, isMain: true)
        let left = monitor("L", -1000, 0, 1000, 1000)
        let t = TestHarness(monitors: [main, left])
        let hiddenWorkspace = t.workspace("hidden")
        t.window(1, in: hiddenWorkspace.rootTilingContainer, frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let floating = t.window(2, in: hiddenWorkspace.floatingWindowsContainer, frame: CGRect(x: 1000, y: 500, width: 300, height: 200))
        t.window(3, in: hiddenWorkspace.floatingWindowsContainer, bundleId: zoomBundleId, frame: CGRect(x: 10, y: 10, width: 300, height: 200))
        t.window(4, in: t.world.activeWorkspace(on: main).rootTilingContainer, frame: CGRect(x: 0, y: 0, width: 2000, height: 999))
        let plan = t.manager.computeLayout()
        #expect(plan.hidden[1] == HideTarget(monitor: "M", monitorVisibleRect: main.visibleFrame, corner: .bottomRight, origin: CGPoint(x: 1999, y: 999)))
        #expect(plan.hidden[3]?.origin == CGPoint(x: 2000, y: 1000)) // Zoom: no 1 pt sliver
        #expect(floating.prevUnhiddenProportionalPosition == CGPoint(x: 0.5, y: 0.5))
        #expect(plan.frames[4] != nil)
        #expect(plan.hidden[4] == nil)
        // The engine parks the window; the read-back doesn't overwrite where it returns to
        t.manager.applied(window: 2, presentedFrame: CGRect(x: 1999, y: 999, width: 300, height: 200))
        _ = t.manager.computeLayout()
        t.run("workspace hidden")
        let shown = t.manager.computeLayout()
        #expect(shown.frames[2] == CGRect(x: 1000, y: 500, width: 300, height: 200))
        #expect(shown.hidden[4] != nil)
        #expect(shown.frames[1] != nil)
        #expect(floating.prevUnhiddenProportionalPosition == nil)
    }

    @Test func bottomLeftHidingUsesTheWindowWidth() {
        let main = monitor("M", 0, 0, 2000, 1000, isMain: true)
        let right = monitor("R", 2000, 0, 1000, 1000)
        let t = TestHarness(monitors: [main, right])
        t.window(1, in: t.workspace("hidden").rootTilingContainer, frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        #expect(t.manager.computeLayout().hidden[1] == HideTarget(monitor: "M", monitorVisibleRect: main.visibleFrame, corner: .bottomLeft, origin: CGPoint(x: -499, y: 999)))
    }
}

@Suite struct WorkspaceSwitchTests {
    @Test func slideDirectionFollowsWorkspaceOrderOnAFreeMonitor() {
        let t = TestHarness()
        t.window(1, in: t.workspace("2").rootTilingContainer)
        t.window(2, in: t.workspace("10").rootTilingContainer)
        t.run("workspace 2")
        _ = t.manager.computeLayout()
        t.run("workspace 10")
        #expect(t.manager.computeLayout().workspaceSwitches == [WorkspaceSwitch(monitor: testMonitor.id, from: "2", to: "10", direction: .left)])
        t.run("workspace 2")
        #expect(t.manager.computeLayout().workspaceSwitches == [WorkspaceSwitch(monitor: testMonitor.id, from: "10", to: "2", direction: .right)])
        #expect(t.manager.computeLayout().workspaceSwitches.isEmpty)
    }

    @Test(arguments: [
        // Neighbour on the right: no horizontal slide, bottom is free
        ([monitor("M", 0, 0, 1000, 1000, isMain: true), monitor("R", 1000, 0, 1000, 1000)], SlideDirection.down),
        // Neighbours right and below
        ([monitor("M", 0, 0, 1000, 1000, isMain: true), monitor("R", 1000, 0, 1000, 1000), monitor("B", 0, 1000, 1000, 1000)], .none),
        // A monitor below only: horizontal edges are free
        ([monitor("M", 0, 0, 1000, 1000, isMain: true), monitor("B", 200, 1000, 500, 500)], .left),
    ])
    func slideDirectionAvoidsNeighbours(monitors: [Monitor], expected: SlideDirection) {
        let t = TestHarness(monitors: monitors)
        #expect(t.world.slideDirection(on: monitors[0], from: "1", to: "2") == expected)
    }
}

