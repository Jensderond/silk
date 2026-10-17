import CoreGraphics
import SilkConfig
import Testing
@testable import SilkCore

/// Regressions for behaviour that used to diverge from AeroSpace.
@Suite struct AeroSpaceParityTests {
    /// The laptop on its own: it's the main display, at the origin.
    static let laptopAlone = Monitor(
        id: "BUILTIN-UUID",
        name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 33, width: 1512, height: 949),
        isMain: true
    )
    /// Docked: the external display becomes the main one at the origin and the laptop moves to its right.
    static let lg = Monitor(
        id: "LG-UUID",
        name: "LG HDR 4K",
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 25, width: 2560, height: 1415),
        isMain: true
    )
    static let laptopDocked = Monitor(
        id: "BUILTIN-UUID",
        name: "Built-in Retina Display",
        frame: CGRect(x: 2560, y: 458, width: 1512, height: 982),
        visibleFrame: CGRect(x: 2560, y: 458, width: 1512, height: 949),
        isMain: false
    )

    /// AeroSpace keys monitors by their top-left corner (`screenPointToVisibleWorkspace`), so when docking moves the
    /// laptop away from the origin, the workspace that was visible there follows the origin to the external display.
    @Test func dockingMovesTheVisibleWorkspaceToTheMonitorAtTheSameScreenPosition() {
        let t = TestHarness(config: UserConfigTests.userConfig().config, monitors: [Self.laptopAlone])
        t.run("workspace 5")
        t.run("workspace 1")
        t.detect(1, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        #expect(t.manager.focusedWorkspace == "1")

        t.manager.monitorsChanged([Self.lg, Self.laptopDocked])
        #expect(t.world.activeWorkspace(on: Self.lg).name == "1")
        // The laptop gets a stub: 1...9 are persistent and 10 is force-assigned, so the first free number
        #expect(t.world.activeWorkspace(on: Self.laptopDocked).name == "11")
        #expect(t.manager.focusedWorkspace == "1")
        #expect(t.manager.computeLayout().frames[1] == CGRect(x: 8, y: 33, width: 2544, height: 1398))

        // Workspaces last shown at the origin now belong to the external display
        #expect(t.world.monitor(of: t.workspace("5")).id == Self.lg.id)
        t.run("workspace 5")
        #expect(t.world.activeWorkspace(on: Self.lg).name == "5")

        // Undocking: the workspace at the origin stays at the origin
        t.manager.monitorsChanged([Self.laptopAlone])
        #expect(t.world.activeWorkspace(on: Self.laptopAlone).name == "5")
        #expect(t.world.monitor(of: t.workspace("1")).id == Self.laptopAlone.id)
    }

    /// Workspace 10 is pinned to the built-in display; after undocking and docking again it's still found there, and
    /// invisible workspaces last shown on the laptop's docked position come back to it.
    @Test func forceAssignedWorkspaceAcrossDocking() {
        let t = TestHarness(config: UserConfigTests.userConfig().config, monitors: [Self.lg, Self.laptopDocked])
        t.run("workspace 10")
        t.detect(2, frame: CGRect(x: 2700, y: 600, width: 800, height: 600))
        t.run("workspace 3")
        #expect(t.world.activeWorkspace(on: Self.laptopDocked).name == "10")
        #expect(t.world.activeWorkspace(on: Self.lg).name == "3")

        t.manager.monitorsChanged([Self.laptopAlone])
        #expect(t.world.activeWorkspace(on: Self.laptopAlone).name == "3")
        #expect(t.world.monitor(of: t.workspace("10")).id == Self.laptopAlone.id)

        t.manager.monitorsChanged([Self.lg, Self.laptopDocked])
        #expect(t.world.activeWorkspace(on: Self.lg).name == "3")
        #expect(t.world.activeWorkspace(on: Self.laptopDocked).name == "10")
    }

    /// AeroSpace `getStubWorkspace` looks the monitor's previously visible workspace up with `Workspace.get(byName:)`,
    /// which recreates it if it was garbage collected in the meantime.
    @Test func stubWorkspaceRecreatesThePreviouslyVisibleWorkspace() {
        let t = TestHarness(config: UserConfigTests.userConfig().config, monitors: [Self.laptopAlone])
        t.run("workspace A")
        t.run("workspace 10")
        t.detect(1, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        #expect(t.world.workspacesByName["A"] == nil) // Empty, invisible and unfocused: garbage collected

        // Docking: workspace 10 can't follow the origin to the external display, which gets a stub instead
        t.manager.monitorsChanged([Self.lg, Self.laptopDocked])
        #expect(t.world.activeWorkspace(on: Self.lg).name == "A")
        #expect(t.world.activeWorkspace(on: Self.laptopDocked).name == "10")
        #expect(t.manager.focusedWorkspace == "10")
        #expect(t.manager.focusedWindow == 1)
    }

    /// AeroSpace's first layout of a workspace creates its floating container, which becomes the workspace's most
    /// recent child: the next new window is appended to the root container instead of following the focused window.
    @Test func firstLayoutCreatesTheFloatingContainer() {
        let t = TestHarness()
        for id: WindowID in [1, 2, 3] { t.detect(id, isFocused: true) }
        t.manager.nativeFocusChanged(window: 1, pid: 1) // The user clicks window 1
        #expect(t.manager.focusedWindow == 1)
        #expect(t.workspace("1").rootTilingContainer.layoutDescription == .h_tiles([.window(1), .window(2), .window(3)]))
        _ = t.manager.computeLayout()
        #expect(t.workspace("1").children.contains { $0 is FloatingWindowsContainer })

        t.detect(4, isFocused: true)
        #expect(t.workspace("1").rootTilingContainer.layoutDescription == .h_tiles([.window(1), .window(2), .window(3), .window(4)]))

        // Once a window is most recent again, new windows follow it
        t.run("focus --window-id 2")
        t.detect(5, isFocused: true)
        #expect(t.workspace("1").rootTilingContainer.layoutDescription == .h_tiles([.window(1), .window(2), .window(5), .window(3), .window(4)]))
    }

    /// When a window dies, AeroSpace snapshots every workspace (`cacheClosedWindowIfNeeded`), creating their missing
    /// special containers. Each becomes its workspace's most recent child, so the next `workspace` switch there
    /// focuses the first window instead of the last focused one.
    @Test func closedWindowSnapshotResetsMostRecentWindowOfOtherWorkspaces() {
        let t = TestHarness()
        t.detect(1, isFocused: true)
        t.detect(2, isFocused: true)
        t.run("workspace 2")
        t.detect(3, isFocused: true)
        t.detect(4, isFocused: true)
        t.run("workspace 1")
        t.run("workspace 2")
        #expect(t.manager.focusedWindow == 4) // The most recent window

        t.run("workspace 1")
        t.manager.windowDestroyed(1)
        #expect(t.manager.focusedWindow == 2)
        t.run("workspace 2")
        #expect(t.manager.focusedWindow == 3)

        // Closing a window with the `close` command doesn't snapshot
        t.run("focus --window-id 4")
        t.run("workspace 1")
        t.run("close --window-id 2")
        t.run("workspace 2")
        #expect(t.manager.focusedWindow == 4)
    }
}
