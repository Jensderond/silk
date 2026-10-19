import CoreGraphics
import SilkConfig
import Testing
@testable import SilkCore

@Suite struct PlatformEventTests {
    let t = TestHarness()

    @Test func newWindowsTileNextToTheMostRecentWindow() {
        t.detect(1)
        t.detect(2)
        t.manager.nativeFocusChanged(window: 1, pid: 1)
        t.detect(3)
        #expect(t.world.focus.workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(1), .window(3), .window(2)]))
    }

    @Test func dialogsFloatAndPopupsAreNotLaidOut() {
        t.detect(1, kind: .dialog)
        t.detect(2, kind: .popup)
        #expect(t.world.focus.workspace.floatingWindows.map(\.id) == [1])
        #expect(t.world.window(byId: 2)?.parent is MacosPopupWindowsContainer)
        let plan = t.manager.computeLayout()
        #expect(plan.frames[1] == CGRect(x: 100, y: 100, width: 800, height: 600))
        #expect(plan.frames[2] == nil)
        #expect(t.run("list-windows --all --count").stdout == "1")

        // A popup that turns out to be a real window is laid out and detected now
        t.manager.windowReclassified(2, kind: .window)
        #expect(t.world.focus.workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(2)]))
        // Native focus on popups is ignored
        t.manager.windowDetected(DetectedWindow(id: 3, pid: 1, bundleId: nil, appName: nil, frame: nil, kind: .popup), isStartup: false)
        t.manager.nativeFocusChanged(window: 3, pid: 1)
        #expect(t.manager.focusedWindow != 3)
    }

    @Test func detectionAtStartupUsesTheMonitorUnderTheWindowCentre() {
        let right = Monitor(id: "R", name: "Right", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080), isMain: false)
        let t = TestHarness(monitors: [testMonitor, right], finishStartup: false)
        t.detect(1, frame: CGRect(x: 2000, y: 100, width: 800, height: 600), isStartup: true)
        #expect(t.world.window(byId: 1)?.nodeWorkspace === t.world.activeWorkspace(on: right))
        t.manager.finishStartup()
        t.detect(2, frame: CGRect(x: 2000, y: 100, width: 800, height: 600))
        #expect(t.world.window(byId: 2)?.nodeWorkspace === t.world.focus.workspace)
    }

    @Test func nativeFocusFollowsMacos() {
        t.detect(1)
        t.detect(2, isFocused: true)
        #expect(t.manager.focusedWindow == 2)
        t.manager.nativeFocusChanged(window: 1, pid: 1)
        #expect(t.manager.focusedWindow == 1)
        // A focus report for a window that isn't detected yet applies once it is
        t.manager.nativeFocusChanged(window: 5, pid: 1)
        t.detect(5)
        #expect(t.manager.focusedWindow == 5)
        // Focusing a window on another workspace switches to it
        t.window(9, in: t.workspace("other").rootTilingContainer)
        t.manager.nativeFocusChanged(window: 9, pid: 0)
        #expect(t.manager.focusedWorkspace == "other")
    }

    @Test func destroyingTheFocusedWindowFocusesTheWorkspacesMostRecentWindow() {
        t.detect(1, pid: 10)
        t.detect(2, pid: 20)
        t.detect(3, pid: 20)
        t.manager.nativeFocusChanged(window: 1, pid: 10)
        t.manager.nativeFocusChanged(window: 3, pid: 20)
        t.platform.focused = []
        t.manager.windowDestroyed(3)
        #expect(t.manager.focusedWindow == 1)
        // The new focus is another app: macOS would keep the windowless app focused, so focus natively
        #expect(t.platform.focused == [1])
        t.manager.windowDestroyed(3) // Unknown ids are ignored
        t.manager.appTerminated(pid: 20)
        #expect(t.world.window(byId: 2) == nil)
    }

    @Test func orderedOutWindowsComeBackToTheirSlot() {
        t.detect(1)
        t.detect(2)
        t.detect(3)
        let root = t.world.focus.workspace.rootTilingContainer
        t.manager.windowOrderedOut(2)
        #expect(root.layoutDescription == .h_tiles([.window(1), .window(3)]))
        #expect(t.manager.computeLayout().frames[2] == nil)
        t.manager.windowOrderedIn(2)
        #expect(root.layoutDescription == .h_tiles([.window(1), .window(2), .window(3)]))
    }

    /// Around the lock screen and display changes (lid closed while docked, monitor unplugged during sleep) macOS
    /// can report live windows as destroyed; they come back with the same id. They return to their old slot, not
    /// the focused workspace, and `on-window-detected` doesn't run again.
    @Test func windowsReportedDestroyedComeBackToTheirSlot() {
        var rule = WindowDetectedRule()
        rule.run = CommandScripts(["move-node-to-workspace detected"])
        let t = TestHarness(config: testConfig { $0.onWindowDetected = [rule] })
        let other = t.workspace("other").rootTilingContainer
        t.window(1, in: other, pid: 10)
        t.window(2, in: other, pid: 10)
        t.window(3, in: other, pid: 10)
        t.window(4, in: t.workspace("other").floatingWindowsContainer, pid: 10)
        #expect(t.world.focus.workspace.name != "other")

        for id: WindowID in [2, 4] { t.manager.windowDestroyed(id) }
        t.detect(2, pid: 10)
        t.detect(4, pid: 10)
        #expect(other.layoutDescription == .h_tiles([.window(1), .window(2), .window(3)]))
        #expect(t.workspace("other").floatingWindows.map(\.id) == [4])
        #expect(t.world.allWorkspaces.map(\.name).contains("detected") == false)

        // Another process reusing the id is a new window
        t.manager.windowDestroyed(3)
        t.detect(3, pid: 20)
        #expect(t.workspace("detected").allLeafWindowsRecursive.map(\.id) == [3])
        // The app quit: its windows are really gone
        t.manager.appTerminated(pid: 10)
        t.detect(1, pid: 10)
        #expect(t.workspace("detected").allLeafWindowsRecursive.map(\.id).sorted() == [1, 3])
    }

    @Test func minimizedAndFullscreenWindowsLeaveTheTreeAndComeBack() {
        t.detect(1)
        let floating = t.detect(2, kind: .dialog)!
        t.detect(3)
        let workspace = t.world.focus.workspace
        t.manager.windowMinimizedChanged(1, isMinimized: true)
        #expect(t.world.window(byId: 1)?.parent is MacosMinimizedWindowsContainer)
        #expect(t.run("list-windows --focused --format %{window-layout}").stdout != "macos_native_minimized")
        t.manager.windowMinimizedChanged(1, isMinimized: false)
        #expect(workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.id).sorted() == [1, 3])

        t.manager.windowFullscreenChanged(2, isFullscreen: true)
        #expect(floating.parent is MacosFullscreenWindowsContainer)
        #expect(t.run(args: ["list-windows", "--workspace", workspace.name, "--format", "%{window-id} %{window-layout}"]).stdout.contains("2 macos_native_fullscreen"))
        #expect(t.manager.computeLayout().frames[2] == nil)
        t.manager.windowFullscreenChanged(2, isFullscreen: false)
        #expect(floating.isFloating)
    }

    @Test func hiddenAppWindows() {
        t.detect(1, pid: 10)
        t.detect(2, pid: 20)
        t.manager.appHidden(pid: 20)
        #expect(t.world.window(byId: 2)?.parent is MacosHiddenAppsWindowsContainer)
        t.manager.appUnhidden(pid: 20)
        #expect(t.world.window(byId: 2)?.parent is TilingContainer)
    }

    @Test func automaticallyUnhideHiddenApps() {
        let t = TestHarness(config: testConfig { $0.automaticallyUnhideMacosHiddenApps = true })
        t.detect(1, pid: 10)
        t.detect(2, pid: 20)
        t.manager.nativeFocusChanged(window: 2, pid: 20)
        t.manager.nativeFocusChanged(window: 1, pid: 10)
        t.manager.appHidden(pid: 10)
        #expect(t.platform.unhidden == [10])
        #expect(t.world.window(byId: 1)?.parent is TilingContainer)
    }

    @Test func disabledQueuesDetectionsAndEnableRegistersThem() {
        t.detect(1)
        #expect(t.run("enable off") == CommandResult(exitCode: 0))
        #expect(t.delegate.enabledChanges == [false])
        #expect(t.manager.activeMode == nil)
        #expect(t.manager.activeBindings.isEmpty)
        t.detect(2)
        #expect(t.world.window(byId: 2) == nil)
        #expect(t.run("workspace b") == CommandResult(exitCode: 2, stderr: WindowManager.disabledMessage))
        #expect(t.run("enable off") == CommandResult(exitCode: 0, stderr: "Already disabled. Tip: use --fail-if-noop to exit with non-zero code"))
        #expect(t.run("enable off --fail-if-noop").exitCode == 2)
        // Disabled: everything is laid out, nothing is hidden
        #expect(t.manager.computeLayout().hidden.isEmpty)

        #expect(t.run("enable toggle").exitCode == 0)
        #expect(t.manager.activeMode == "main")
        #expect(t.world.window(byId: 2) != nil)
        #expect(parseScript("enable toggle --fail-if-noop").errorOrNil == "--fail-if-noop is incompatible with 'toggle' argument")
    }

    @Test func appChangedFrameAndApplied() {
        let floating = t.detect(1, kind: .dialog)!
        t.manager.appChangedFrame(window: 1, frame: CGRect(x: 50, y: 60, width: 300, height: 200))
        #expect(t.manager.needsLayout)
        #expect(t.manager.computeLayout().frames[1] == CGRect(x: 50, y: 60, width: 300, height: 200))
        #expect(!t.manager.needsLayout)
        t.manager.applied(window: 1, presentedFrame: CGRect(x: 51, y: 60, width: 300, height: 200))
        #expect(floating.lastKnownFrame == CGRect(x: 51, y: 60, width: 300, height: 200))
        t.manager.windowTitleChanged(1, title: "New title")
        #expect(t.run("list-windows --all --format %{window-title}").stdout == "New title")
    }
}

@Suite struct CallbackTests {
    @Test func onWindowDetectedRules() {
        var titleRule = WindowDetectedRule()
        titleRule.matcher.windowTitleRegexSubstring = "^inbox"
        titleRule.run = CommandScripts(["move-node-to-workspace mail"])
        titleRule.checkFurtherCallbacks = true
        var ifRule = WindowDetectedRule()
        ifRule.ifCommand = "test %{app-bundle-id} = com.apple.mail"
        ifRule.run = CommandScripts(["layout floating"])
        var neverReached = WindowDetectedRule()
        neverReached.run = CommandScripts(["move-node-to-workspace never"])
        var startupOnly = WindowDetectedRule()
        startupOnly.matcher.duringStartup = true
        startupOnly.run = CommandScripts(["move-node-to-workspace startup"])
        let t = TestHarness(config: testConfig { $0.onWindowDetected = [startupOnly, titleRule, ifRule, neverReached] })

        t.detect(1, bundleId: "com.apple.mail", title: "Inbox (3)")
        #expect(t.workspace("mail").floatingWindows.map(\.id) == [1])
        #expect(t.world.allWorkspaces.map(\.name).contains("never") == false)

        t.detect(2, bundleId: "com.other", title: "x")
        #expect(t.workspace("never").allLeafWindowsRecursive.map(\.id) == [2])
    }

    @Test func runCallback() {
        var rule = WindowDetectedRule()
        rule.matcher.appNameRegexSubstring = "term"
        rule.run = CommandScripts(["move-node-to-workspace t"])
        let t = TestHarness(config: testConfig {
            $0.onWindowDetected = [rule]
            $0.onFocusChanged = CommandScripts(["exec-and-forget echo focus"])
        })
        t.window(1, in: t.workspace("a").rootTilingContainer, appName: "Terminal")
        t.window(2, in: t.workspace("a").rootTilingContainer, appName: "Safari")
        #expect(t.run("run-callback --window-id 1 on-window-detected").exitCode == 0)
        #expect(t.workspace("t").allLeafWindowsRecursive.map(\.id) == [1])
        // No matching rule: AeroSpace's exit code 2
        #expect(t.run("run-callback --window-id 2 on-window-detected").exitCode == 2)
        #expect(t.run("run-callback --for-every-window on-window-detected").exitCode == 2)
        t.platform.execs = []
        #expect(t.run("run-callback on-focus-changed").exitCode == 0)
        #expect(t.platform.execScripts == [" echo focus"])
        #expect(parseScript("run-callback --for-every-window on-focus-changed").errorOrNil == "--for-every-window is only allowed with 'on-window-detected'")
        #expect(parseScript("run-callback --window-id 1 on-focused-monitor-changed").errorOrNil == "--window-id is only allowed with 'on-window-detected'")
        #expect(parseScript("run-callback --for-every-window --window-id 1 on-window-detected").errorOrNil == "ERROR: Conflicting options: --for-every-window, --window-id")
        #expect(parseScript("run-callback bogus").errorOrNil == "ERROR: Can't parse 'bogus'.\n       Possible values: (on-window-detected|on-focus-changed|on-focused-monitor-changed)")
    }

    @Test func focusCallbacksAndWorkspaceChangeExec() {
        let t = TestHarness(config: testConfig {
            $0.onFocusChanged = CommandScripts(["exec-and-forget focus-changed"])
            $0.execOnWorkspaceChange = ["/bin/bash", "-c", "echo $AEROSPACE_FOCUSED_WORKSPACE"]
        })
        t.window(1, in: t.workspace("a").rootTilingContainer)
        t.window(2, in: t.workspace("b").rootTilingContainer)
        t.run("workspace a")
        t.platform.execs = []
        t.platform.events = []
        t.run("workspace b")
        #expect(t.platform.execs.map(\.script) == [" focus-changed", "exec '/bin/bash' '-c' 'echo $AEROSPACE_FOCUSED_WORKSPACE'"])
        #expect(t.platform.execs[0].env["AEROSPACE_WINDOW_ID"] == "2")
        let workspaceEnv = t.platform.execs[1].env
        #expect(workspaceEnv["AEROSPACE_FOCUSED_WORKSPACE"] == "b")
        #expect(workspaceEnv["AEROSPACE_PREV_WORKSPACE"] == "a")
        #expect(workspaceEnv["AEROSPACE_WINDOW_ID"] == "2")
        #expect(workspaceEnv["AEROSPACE_WORKSPACE"] == nil)
        #expect(t.platform.events == [.focusChanged(windowId: 2, workspace: "b"), .workspaceChanged(workspace: "b", prevWorkspace: "a")])
    }

    @Test func modeChanges() {
        let t = TestHarness(config: testConfig {
            $0.modes = ["main": mode("main", binding("alt-r", "mode resize")), "resize": mode("resize", binding("h", "resize width -50"), binding("esc", "mode main"))]
            $0.onModeChanged = CommandScripts(["exec-and-forget mode-changed"])
        })
        #expect(parseSingle("mode -- --foo", as: ModeCommand.self)?.targetMode == "--foo")
        #expect(parseScript("mode").errorOrNil == "ERROR: Argument '<binding-mode>' is mandatory")
        t.manager.handleHotkey("alt-r")
        #expect(t.manager.activeMode == "resize")
        #expect(t.delegate.activatedModes == ["resize"])
        #expect(t.platform.execScripts == [" mode-changed"])
        #expect(t.platform.events.contains(.modeChanged(mode: "resize")))
        #expect(t.manager.activeBindings.map(\.descriptor) == ["esc", "h"])
        #expect(t.manager.menuBarModel().text == "(R) 1")
        t.run("mode resize") // Same mode: hotkeys refresh, no callback
        #expect(t.platform.execScripts.count == 1)
        #expect(t.delegate.activatedModes.count == 2)

        #expect(t.run("trigger-binding --mode main alt-r").exitCode == 0)
        #expect(t.run("trigger-binding --mode main alt-x") == CommandResult(exitCode: 2, stderr: "Binding 'alt-x' is not presented in mode 'main'"))
        #expect(t.run("trigger-binding --mode foo alt-x") == CommandResult(exitCode: 2, stderr: "Mode 'foo' doesn't exist. Available modes: main,resize"))
        #expect(parseScript("trigger-binding foo").errorOrNil == "--mode flag is mandatory")
        #expect(parseSingle("trigger-binding --mode main -- --fail-if-noop", as: TriggerBindingCommand.self)?.binding == "--fail-if-noop")
    }

    @Test func callbacksAreSuppressedDuringStartup() {
        let t = TestHarness(config: testConfig { $0.onFocusChanged = CommandScripts(["exec-and-forget x"]) }, finishStartup: false)
        t.detect(1, isStartup: true)
        t.detect(2, isStartup: true)
        #expect(t.platform.execs.isEmpty)
        t.manager.finishStartup()
        t.detect(3)
        #expect(t.platform.execs.isEmpty) // The first check after startup only records the focus
        t.manager.nativeFocusChanged(window: 1, pid: 1)
        #expect(t.platform.execScripts == [" x"])
    }
}
