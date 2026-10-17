import CoreGraphics
import SilkConfig
import Testing
@testable import SilkCore

@Suite struct MouseTests {
    let left = Monitor(id: "L", name: "Left", frame: CGRect(x: 0, y: 0, width: 1000, height: 801), visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 801), isMain: true)
    let right = Monitor(id: "R", name: "Right", frame: CGRect(x: 1000, y: 0, width: 1000, height: 801), visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 801), isMain: false)

    /// Three tiles of 1000 x 800 on the left monitor: 0-333, 333-667, 667-1000.
    private func threeTiles() -> (TestHarness, Workspace) {
        let t = TestHarness(monitors: [left, right])
        let workspace = t.world.activeWorkspace(on: left)
        for id: WindowID in 1 ... 3 { t.window(id, in: workspace.rootTilingContainer) }
        t.focus(t.world.window(byId: 1)!)
        _ = t.manager.computeLayout()
        return (t, workspace)
    }

    @Test func draggingATileOverAnotherSwapsThem() {
        let (t, workspace) = threeTiles()
        let tile = t.world.window(byId: 1)!.lastAppliedLayoutPhysicalRect!
        t.platform.mouseLocation = CGPoint(x: 800, y: 400)
        t.manager.userManipulation(window: 1, frame: tile.offsetBy(dx: 600, dy: 0), phase: .changed)
        #expect(workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(3), .window(2), .window(1)]))
        let during = t.manager.computeLayout()
        #expect(during.frames[1] == nil) // The dragged window follows the mouse
        #expect(during.userDriven == [1, 2, 3])
        #expect(during.frames[3]!.minX == 0)
        #expect(during.frames[3]!.width.isNearly(1000.0 / 3))

        // Further move events over the same tile don't swap back
        t.manager.userManipulation(window: 1, frame: tile.offsetBy(dx: 610, dy: 0), phase: .changed)
        #expect(workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(3), .window(2), .window(1)]))

        t.manager.userManipulation(window: 1, frame: tile.offsetBy(dx: 610, dy: 0), phase: .ended)
        let after = t.manager.computeLayout()
        #expect(after.frames[1]!.minX.isNearly(2000.0 / 3))
        #expect(after.frames[1]!.height == 800)
        #expect(after.userDriven.isEmpty)
    }

    @Test func draggingATileToAnotherMonitorInsertsIt() {
        let (t, workspace) = threeTiles()
        let other = t.world.activeWorkspace(on: right)
        t.window(4, in: other.rootTilingContainer)
        _ = t.manager.computeLayout()
        t.platform.mouseLocation = CGPoint(x: 1800, y: 400) // Right half of window 4
        t.manager.userManipulation(window: 2, frame: CGRect(x: 1500, y: 100, width: 333, height: 800), phase: .changed)
        #expect(other.rootTilingContainer.layoutDescription == .h_tiles([.window(4), .window(2)]))
        #expect(workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(1), .window(3)]))
        t.manager.leftMouseUp(at: CGPoint(x: 1800, y: 400))
        #expect(t.world.manipulatedWindowId == nil)
    }

    @Test func resizingATileAdjustsWeights() {
        let (t, workspace) = threeTiles()
        let window2 = t.world.window(byId: 2)!
        let tile = window2.lastAppliedLayoutPhysicalRect!
        // Drag the right edge 60 pt to the right
        t.manager.userManipulation(window: 2, frame: CGRect(x: tile.minX, y: tile.minY, width: tile.width + 60, height: tile.height), phase: .changed)
        let root = workspace.rootTilingContainer
        #expect(window2.hWeight.isNearly(1000.0 / 3 + 60))
        #expect(root.children[2].hWeight.isNearly(1000.0 / 3 - 60))
        #expect(root.children[0].hWeight.isNearly(1000.0 / 3))
        let plan = t.manager.computeLayout()
        #expect(plan.frames[2] == nil)
        #expect(plan.frames[3]!.minX.isNearly(2000.0 / 3 + 60))
        // Continuing the same gesture is relative to its start, not cumulative
        t.manager.userManipulation(window: 2, frame: CGRect(x: tile.minX, y: tile.minY, width: tile.width + 90, height: tile.height), phase: .changed)
        #expect(window2.hWeight.isNearly(1000.0 / 3 + 90))
        t.manager.userManipulation(window: 2, frame: CGRect(x: tile.minX, y: tile.minY, width: tile.width + 90, height: tile.height), phase: .ended)
        #expect(t.manager.computeLayout().frames[2]!.width.isNearly(1000.0 / 3 + 90))
        // Small jitter (≤ 5 pt) is ignored
        t.manager.userManipulation(window: 1, frame: CGRect(x: 0, y: 0, width: 1000.0 / 3 + 3, height: 799), phase: .ended)
        #expect(t.world.window(byId: 1)!.hWeight.isNearly(1000.0 / 3))
    }

    @Test func floatingWindowsJoinTheWorkspaceOfTheMonitorTheyAreDraggedTo() {
        let t = TestHarness(monitors: [left, right])
        let window = t.window(1, in: t.world.activeWorkspace(on: left).floatingWindowsContainer, frame: CGRect(x: 100, y: 100, width: 300, height: 200))
        t.manager.userManipulation(window: 1, frame: CGRect(x: 1200, y: 100, width: 300, height: 200), phase: .changed)
        #expect(window.nodeWorkspace === t.world.activeWorkspace(on: right))
        #expect(t.manager.computeLayout().frames[1] == nil)
        t.manager.userManipulation(window: 1, frame: CGRect(x: 1210, y: 100, width: 300, height: 200), phase: .ended)
        #expect(t.manager.computeLayout().frames[1] == CGRect(x: 1210, y: 100, width: 300, height: 200))
    }

    @Test func clickingAnotherMonitorsDesktopFocusesItsWorkspace() {
        let t = TestHarness(monitors: [left, right])
        let rightWorkspace = t.world.activeWorkspace(on: right)
        t.window(5, in: rightWorkspace.rootTilingContainer)
        t.manager.leftMouseUp(at: CGPoint(x: 1500, y: 300))
        #expect(t.manager.focusedWorkspace == rightWorkspace.name)
        #expect(t.platform.focused == [5])
    }

    @Test func focusFollowsMouse() {
        let t = TestHarness(config: testConfig { $0.focusFollowsMouse = true }, monitors: [left, right])
        let workspace = t.world.activeWorkspace(on: left)
        t.window(1, in: workspace.rootTilingContainer)
        t.window(2, in: workspace.rootTilingContainer)
        t.window(3, in: workspace.floatingWindowsContainer, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        _ = t.manager.computeLayout()
        #expect(t.manager.focusFollowsMouse(at: CGPoint(x: 700, y: 400)) == 2)
        #expect(t.manager.focusedWindow == 2)
        #expect(t.manager.focusFollowsMouse(at: CGPoint(x: 50, y: 50)) == 3) // Floating windows first
        #expect(t.platform.focused == [2, 3])
    }

    @Test func moveMouseCommand() {
        let t = TestHarness(monitors: [left, right])
        t.platform.mouseLocation = CGPoint(x: 10, y: 10)
        let window = t.window(1, in: t.world.activeWorkspace(on: right).rootTilingContainer)
        t.focus(window)
        _ = t.manager.computeLayout()
        #expect(t.run("move-mouse window-lazy-center").exitCode == 0)
        #expect(t.platform.mouseMoves == [CGPoint(x: 1500, y: 400)])
        #expect(t.run("move-mouse window-lazy-center") == CommandResult(exitCode: 0, stderr: "The mouse already belongs to the window. Tip: use --fail-if-noop to exit with non-zero code"))
        #expect(t.run("move-mouse --fail-if-noop monitor-lazy-center").exitCode == 2)
        #expect(t.run("move-mouse monitor-force-center").exitCode == 0)
        #expect(t.platform.mouseMoves.last == CGPoint(x: 1500, y: 400.5))
        #expect(parseScript("move-mouse --fail-if-noop window-force-center").errorOrNil == "--fail-if-noop is only compatible with window-lazy-center or monitor-lazy-center")
    }
}

extension CGFloat {
    func isNearly(_ other: CGFloat) -> Bool { abs(self - other) < 0.01 }
}
