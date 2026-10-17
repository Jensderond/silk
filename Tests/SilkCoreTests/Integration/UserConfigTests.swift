import CoreGraphics
import SilkConfig
import Testing
@testable import SilkCore

/// End-to-end runs of the user's real config on a fake world with an external main display and the laptop to its
/// right.
@Suite struct UserConfigTests {
    static let dell = Monitor(
        id: "DELL-UUID",
        name: "DELL U2723QE",
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 25, width: 2560, height: 1415),
        isMain: true
    )
    static let laptop = Monitor(
        id: "BUILTIN-UUID",
        name: "Built-in Retina Display",
        frame: CGRect(x: 2560, y: 458, width: 1512, height: 982),
        visibleFrame: CGRect(x: 2560, y: 458, width: 1512, height: 949),
        isMain: false
    )
    static let slackBundleId = "com.tinyspeck.slackmacgap"

    static func userConfig() -> ConfigLoadResult { ConfigLoader.parse(userConfigTOML, url: nil) }

    let t: TestHarness

    init() {
        t = TestHarness(config: Self.userConfig().config, monitors: [Self.dell, Self.laptop], finishStartup: false)
        t.platform.mouseLocation = CGPoint(x: 100, y: 100)
        t.platform.reloadResult = Self.userConfig()
    }

    private func detect(_ id: WindowID, at frame: CGRect, bundleId: String = "com.example.app", appName: String = "Example", isStartup: Bool = false) {
        t.detect(id, pid: pid_t(id), bundleId: bundleId, appName: appName, title: "Window \(id)", frame: frame, isStartup: isStartup)
    }

    /// Runs `~/.slack-placement.sh` the way the CLI would: through `run(args:)`.
    private func runSlackPlacementScript() {
        let count = Int(t.run(args: ["list-monitors", "--count"]).stdout) ?? 0
        let target = count >= 2 ? "10" : "4"
        let lines = t.run(args: ["list-windows", "--all", "--format", "%{window-id}|%{app-bundle-id}"]).stdout.split(separator: "\n")
        for line in lines {
            let parts = line.split(separator: "|").map(String.init)
            if parts.count == 2 && parts[1] == Self.slackBundleId {
                #expect(t.run(args: ["move-node-to-workspace", "--window-id", parts[0], target]).exitCode == 0)
            }
        }
    }

    @Test func configHasNoErrors() {
        let result = Self.userConfig()
        #expect(result.errors.isEmpty)
        #expect(t.manager.configDiagnostics.isEmpty)
        #expect(t.manager.activeBindings.count == 82)
        #expect(Set(t.world.allWorkspaces.map(\.name)).isSuperset(of: (1 ... 9).map(String.init)))
    }

    @Test func startupBindsWindowsByMonitorAndRunsAfterStartupCommand() {
        detect(1, at: CGRect(x: 100, y: 100, width: 800, height: 600), isStartup: true)
        detect(2, at: CGRect(x: 2700, y: 600, width: 800, height: 600), isStartup: true)
        let dellWorkspace = t.world.activeWorkspace(on: Self.dell)
        let laptopWorkspace = t.world.activeWorkspace(on: Self.laptop)
        #expect(dellWorkspace.allLeafWindowsRecursive.map(\.id) == [1])
        #expect(laptopWorkspace.allLeafWindowsRecursive.map(\.id) == [2])
        #expect(dellWorkspace.name == "1")
        #expect(t.platform.mouseMoves.isEmpty) // Focus callbacks are suppressed during startup

        t.manager.finishStartup()
        #expect(t.platform.execScripts == [" ~/.slack-placement.sh"])
        #expect(t.platform.execs[0].env["PATH"] == "/opt/homebrew/bin:/opt/homebrew/sbin:")
        #expect(!t.manager.isStartup)
    }

    @Test func slackIsPlacedOnTheLaptopWorkspace() {
        t.manager.finishStartup()
        detect(1, at: CGRect(x: 100, y: 100, width: 800, height: 600))
        detect(77, at: CGRect(x: 300, y: 300, width: 1000, height: 700), bundleId: Self.slackBundleId, appName: "Slack")
        let ruleExec = t.platform.execs.last
        #expect(ruleExec?.script == " ~/.slack-placement.sh")
        #expect(ruleExec?.env["AEROSPACE_WINDOW_ID"] == "77")
        #expect(t.platform.events.contains(.windowDetected(windowId: 77, workspace: "1", appBundleId: Self.slackBundleId, appName: "Slack")))

        runSlackPlacementScript()
        let workspace10 = t.workspace("10")
        #expect(workspace10.allLeafWindowsRecursive.map(\.id) == [77])
        #expect(t.world.monitor(of: workspace10).id == Self.laptop.id)
        let plan = t.manager.computeLayout()
        #expect(plan.hidden[77]?.monitor == Self.laptop.id)
        #expect(plan.hidden[77]?.corner == .bottomRight)
        #expect(plan.frames[1] != nil)

        // With one monitor the script routes Slack to workspace 4
        t.manager.monitorsChanged([Self.dell])
        runSlackPlacementScript()
        #expect(t.workspace("4").allLeafWindowsRecursive.map(\.id) == [77])
    }

    @Test func workspaceBindingsAndMonitorFocusCallback() {
        t.manager.finishStartup()
        detect(1, at: CGRect(x: 100, y: 100, width: 800, height: 600))
        _ = t.manager.computeLayout()

        // alt-0: workspace 10 is pinned to the built-in display
        t.manager.handleHotkey("alt-0")
        #expect(t.manager.focusedWorkspace == "10")
        #expect(t.world.activeWorkspace(on: Self.laptop).name == "10")
        #expect(t.platform.events.contains(.bindingTriggered(mode: "main", binding: "alt-0")))
        // on-focused-monitor-changed = 'move-mouse monitor-lazy-center'
        #expect(t.platform.mouseMoves == [Self.laptop.frame.center])
        #expect(t.platform.events.contains(.focusedMonitorChanged(workspace: "10", monitorId: 2)))
        #expect(t.platform.events.contains(.workspaceChanged(workspace: "10", prevWorkspace: "1")))

        let plan = t.manager.computeLayout()
        #expect(plan.workspaceSwitches == [WorkspaceSwitch(monitor: Self.laptop.id, from: "11", to: "10", direction: .down)])

        // alt-tab: workspace-back-and-forth
        t.manager.handleHotkey("alt-tab")
        #expect(t.manager.focusedWorkspace == "1")
        #expect(t.platform.mouseMoves == [Self.laptop.frame.center, Self.dell.frame.center])

        // alt-shift-2 moves the focused window, alt-2 follows it
        t.manager.handleHotkey("alt-shift-2")
        #expect(t.workspace("2").allLeafWindowsRecursive.map(\.id) == [1])
        t.manager.handleHotkey("alt-2")
        #expect(t.manager.focusedWindow == 1)
    }

    @Test func moveWorkspaceToMonitorWrapsAround() {
        t.manager.finishStartup()
        detect(1, at: CGRect(x: 100, y: 100, width: 800, height: 600))
        // alt-shift-tab = 'move-workspace-to-monitor --wrap-around next'
        t.manager.handleHotkey("alt-shift-tab")
        #expect(t.world.activeWorkspace(on: Self.laptop).name == "1")
        #expect(t.world.activeWorkspace(on: Self.dell).name == "2")
        #expect(t.manager.focusedWorkspace == "1")
        t.manager.handleHotkey("alt-shift-tab")
        #expect(t.world.activeWorkspace(on: Self.dell).name == "1")
        // Workspace 10 can't leave the built-in display
        t.manager.handleHotkey("alt-0")
        let result = t.manager.run(script: "move-workspace-to-monitor --wrap-around next")
        #expect(result == CommandResult(exitCode: 2, stderr: "Can't move workspace '10' to monitor 'DELL U2723QE'. workspace-to-monitor-force-assignment doesn't allow it"))
    }

    @Test func tilingBindingsWithGaps() {
        t.manager.finishStartup()
        detect(1, at: CGRect(x: 100, y: 100, width: 800, height: 600))
        detect(2, at: CGRect(x: 200, y: 200, width: 800, height: 600))
        #expect(t.manager.focusedWindow == 2)
        var plan = t.manager.computeLayout()
        #expect(t.manager.focusedWindow == 2)
        // 8 pt outer gaps around the visible frame, 8 pt between the tiles, AeroSpace's `height - 1`
        #expect(plan.frames[1] == CGRect(x: 8, y: 33, width: 1268, height: 1398))
        #expect(plan.frames[2] == CGRect(x: 1284, y: 33, width: 1268, height: 1398))
        #expect(plan.newlyPlaced == [1: CGRect(x: 100, y: 100, width: 800, height: 600), 2: CGRect(x: 200, y: 200, width: 800, height: 600)])

        t.manager.handleHotkey("alt-equal") // resize smart +50
        plan = t.manager.computeLayout()
        #expect(plan.frames[2]?.width == 1318)
        #expect(plan.newlyPlaced.isEmpty)

        t.manager.handleHotkey("alt-h") // focus left
        #expect(t.manager.focusedWindow == 1)
        t.manager.handleHotkey("alt-shift-l") // move right
        #expect(t.world.focus.workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(2), .window(1)]))
        t.manager.handleHotkey("alt-slash") // layout tiles horizontal vertical
        #expect(t.world.focus.workspace.rootTilingContainer.layoutDescription == .v_tiles([.window(2), .window(1)]))
        t.manager.handleHotkey("alt-comma") // layout accordion horizontal vertical: the first non-matching is 'accordion'
        #expect(t.world.focus.workspace.rootTilingContainer.layoutDescription == .v_accordion([.window(2), .window(1)]))
        plan = t.manager.computeLayout()
        // Accordion: 30 pt padding on the inner side of each child
        #expect(plan.frames[2] == CGRect(x: 8, y: 33, width: 2544, height: 1368))
        #expect(plan.frames[1] == CGRect(x: 8, y: 63, width: 2544, height: 1368))
    }

    @Test func serviceMode() {
        t.manager.finishStartup()
        detect(1, at: CGRect(x: 100, y: 100, width: 800, height: 600))
        detect(2, at: CGRect(x: 200, y: 200, width: 800, height: 600))
        detect(3, at: CGRect(x: 300, y: 300, width: 800, height: 600))
        let root = { self.t.world.focus.workspace.rootTilingContainer }

        t.manager.handleHotkey("alt-shift-semicolon")
        #expect(t.manager.activeMode == "service")
        #expect(t.delegate.activatedModes.last == "service")
        #expect(t.platform.events.contains(.modeChanged(mode: "service")))
        #expect(t.manager.activeBindings.map(\.descriptor) == ["alt-shift-h", "alt-shift-j", "alt-shift-k", "alt-shift-l", "backspace", "esc", "f", "p", "r"])
        #expect(t.manager.handleHotkey("alt-1") == nil) // Not bound in service mode

        t.manager.handleHotkey("alt-shift-h") // join-with left; mode main
        #expect(root().layoutDescription == .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
        #expect(t.manager.activeMode == "main")

        t.manager.handleHotkey("alt-shift-semicolon")
        t.manager.handleHotkey("r") // flatten-workspace-tree; mode main
        #expect(root().layoutDescription == .h_tiles([.window(1), .window(2), .window(3)]))

        t.manager.handleHotkey("alt-shift-semicolon")
        t.manager.handleHotkey("f") // layout floating tiling; mode main
        #expect(t.world.focus.workspace.floatingWindows.map(\.id) == [3])
        t.manager.handleHotkey("alt-shift-semicolon")
        t.manager.handleHotkey("f")
        #expect(t.world.focus.workspace.floatingWindows.isEmpty)

        t.manager.handleHotkey("alt-shift-semicolon")
        t.manager.handleHotkey("backspace") // close-all-windows-but-current; mode main
        #expect(t.platform.closed.sorted() == [1, 2])
        #expect(t.world.focus.workspace.allLeafWindowsRecursive.map(\.id) == [3])

        t.manager.handleHotkey("alt-shift-semicolon")
        t.manager.handleHotkey("esc") // reload-config; mode main
        #expect(t.delegate.reloadedConfigs == 1)
        #expect(t.delegate.configMessages.last == .some(nil))
        #expect(t.manager.activeMode == "main")

        t.manager.handleHotkey("alt-shift-semicolon")
        t.manager.handleHotkey("p")
        #expect(t.platform.execScripts.last == " ~/.slack-placement.sh")
        #expect(t.manager.activeMode == "main")

        t.manager.handleHotkey("alt-enter")
        #expect(t.platform.execScripts.last == " open -n /Applications/Ghostty.app")
    }

    @Test func monitorDisconnectAndReconnect() {
        t.manager.finishStartup()
        detect(1, at: CGRect(x: 100, y: 100, width: 800, height: 600))
        t.manager.handleHotkey("alt-0")
        detect(2, at: CGRect(x: 2700, y: 600, width: 800, height: 600))
        #expect(t.workspace("10").allLeafWindowsRecursive.map(\.id) == [2])

        t.manager.monitorsChanged([Self.dell])
        // The laptop's workspace is now invisible and belongs to the nearest monitor; focus stays on it (AeroSpace)
        #expect(t.world.monitor(of: t.workspace("10")).id == Self.dell.id)
        #expect(t.manager.focusedWorkspace == "10")
        #expect(t.manager.computeLayout().hidden[2]?.monitor == Self.dell.id)
        #expect(t.run("workspace 10").stderr == "Workspace '10' is already focused. Tip: use --fail-if-noop to exit with non-zero code")
        t.manager.handleHotkey("alt-1")
        t.manager.handleHotkey("alt-0")
        #expect(t.world.activeWorkspace(on: Self.dell).name == "10")
        #expect(t.manager.computeLayout().frames[2] != nil)

        t.manager.handleHotkey("alt-1")
        t.manager.monitorsChanged([Self.dell, Self.laptop])
        #expect(t.world.activeWorkspace(on: Self.laptop).name == "10")
        #expect(t.world.activeWorkspace(on: Self.dell).name == "1")
    }
}
