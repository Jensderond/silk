import CoreGraphics
import Foundation
import SilkConfig
import Testing
@testable import SilkCore

@Suite struct FrozenWorldTests {
    let right = Monitor(id: "R", name: "Right", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080), isMain: false)

    private func populated() -> TestHarness {
        let t = TestHarness(monitors: [testMonitor, right])
        t.detect(1)
        t.detect(2)
        t.detect(3)
        t.manager.nativeFocusChanged(window: 2, pid: 1)
        t.run("join-with right")
        t.run("resize smart +100")
        t.detect(4, kind: .dialog)
        t.run("move-node-to-workspace --window-id 4 B")
        t.run("layout --workspace B --root accordion")
        t.run("workspace C")
        t.detect(5)
        t.run("move-workspace-to-monitor right")
        _ = t.manager.computeLayout()
        return t
    }

    @Test func roundTripsThroughJSON() throws {
        let frozen = populated().manager.frozenWorld()
        let decoded = try JSONDecoder().decode(FrozenWorld.self, from: JSONEncoder().encode(frozen))
        #expect(decoded == frozen)
        #expect(frozen.windowIds == [1, 2, 3, 4, 5])
        #expect(frozen.focusedWorkspace == "C")
        #expect(frozen.focusedWindowId == 5)
        #expect(frozen.visibleWorkspaces["R"] == "C")
    }

    @Test func restoreRebuildsTreesAsWindowsAreDetected() {
        let original = populated()
        let frozen = original.manager.frozenWorld()
        let originalWorkspace1 = original.workspace("1").rootTilingContainer.layoutDescription

        let t = TestHarness(monitors: [testMonitor, right], finishStartup: false)
        t.manager.restore(frozen)
        #expect(t.manager.focusedWorkspace == "C")
        #expect(t.world.activeWorkspace(on: right).name == "C")
        for id: WindowID in [3, 1, 5, 2, 4] {
            t.detect(id, kind: id == 4 ? .dialog : .window, isStartup: true)
        }
        t.manager.finishStartup()
        #expect(t.workspace("1").rootTilingContainer.layoutDescription == originalWorkspace1)
        #expect(t.workspace("1").rootTilingContainer.layout == .tiles) // The startup layout doesn't override a restore
        #expect(t.workspace("B").floatingWindows.map(\.id) == [4])
        #expect(t.workspace("B").rootTilingContainer.layout == .accordion)
        #expect(t.workspace("C").allLeafWindowsRecursive.map(\.id) == [5])
        #expect(t.manager.focusedWindow == 5)
        let weights = t.workspace("1").rootTilingContainer.children.map { $0.getWeight(.h) }
        let originalWeights = original.workspace("1").rootTilingContainer.children.map { $0.getWeight(.h) }
        #expect(weights == originalWeights)
        #expect(t.world.pendingRestore == nil)
        // Restored windows don't run on-window-detected
        #expect(!t.platform.events.contains { $0.type == .windowDetected && $0.windowId == 1 })
    }

    @Test func partiallyDetectedSnapshotsKeepWaiting() {
        let frozen = populated().manager.frozenWorld()
        let t = TestHarness(monitors: [testMonitor, right])
        t.manager.restore(frozen)
        t.detect(1)
        t.detect(3)
        #expect(t.workspace("1").rootTilingContainer.allLeafWindowsRecursive.map(\.id) == [1, 3])
        #expect(t.world.pendingRestore != nil)
        t.detect(99) // Unknown windows are placed normally
        #expect(t.world.window(byId: 99)?.nodeWorkspace != nil)
    }
}

@Suite struct ServerEventTests {
    @Test func jsonMatchesAeroSpace() {
        func json(_ event: ServerEvent) -> String { String(data: event.jsonData(), encoding: .utf8)! }
        #expect(json(.focusChanged(windowId: 42, workspace: "1")) == #"{"_event":"focus-changed","windowId":42,"workspace":"1"}"#)
        #expect(json(.focusChanged(windowId: nil, workspace: "a/b")) == #"{"_event":"focus-changed","workspace":"a/b"}"#)
        #expect(json(.focusedMonitorChanged(workspace: "2", monitorId: 2)) == #"{"_event":"focused-monitor-changed","monitorId":2,"workspace":"2"}"#)
        #expect(json(.workspaceChanged(workspace: "2", prevWorkspace: "1")) == #"{"_event":"focused-workspace-changed","prevWorkspace":"1","workspace":"2"}"#)
        #expect(json(.modeChanged(mode: nil)) == #"{"_event":"mode-changed"}"#)
        #expect(json(.windowDetected(windowId: 7, workspace: "1", appBundleId: "com.x", appName: "X")) == #"{"_event":"window-detected","appBundleId":"com.x","appName":"X","windowId":7,"workspace":"1"}"#)
        #expect(json(.bindingTriggered(mode: "main", binding: "alt-h")) == #"{"_event":"binding-triggered","binding":"alt-h","mode":"main"}"#)
        let decoded = try? JSONDecoder().decode(ServerEvent.self, from: ServerEvent.modeChanged(mode: "service").jsonData())
        #expect(decoded == .modeChanged(mode: "service"))
    }

    @Test func subscribeArguments() {
        #expect(WindowManager.parseSubscribe(args: ["focus-changed", "mode-changed"]) == .subscribe(events: [.focusChanged, .modeChanged], sendInitial: true))
        #expect(WindowManager.parseSubscribe(args: ["--all", "--no-send-initial"]) == .subscribe(events: Set(ServerEventType.allCases), sendInitial: false))
        #expect(WindowManager.parseSubscribe(args: ["unknown-event"]) == .failure(message: "ERROR: Can't parse 'unknown-event'.\n       Possible values: (focus-changed|focused-monitor-changed|focused-workspace-changed|mode-changed|window-detected|binding-triggered)", exitCode: 2))
        #expect(WindowManager.parseSubscribe(args: ["focus-changed", "focus-changed"]) == .failure(message: "ERROR: Duplicate event 'focus-changed'", exitCode: 2))
        #expect(WindowManager.parseSubscribe(args: []) == .failure(message: "Either --all or at least one <event> must be specified", exitCode: 2))
        #expect(WindowManager.parseSubscribe(args: ["--all", "focus-changed"]) == .failure(message: "--all conflicts with specifying individual events", exitCode: 2))
        #expect(WindowManager.parseSubscribe(args: ["--help"]) == .help(HelpText.subscribe))
        let t = TestHarness()
        #expect(t.run(args: ["subscribe", "--all"]) == CommandResult(exitCode: 2, stderr: "subscribe is not supported in the eval"))
    }

    @Test func initialSubscribeEvents() {
        let t = TestHarness()
        t.detect(3)
        #expect(t.manager.initialSubscribeEvents(for: Set(ServerEventType.allCases)) == [
            .focusChanged(windowId: 3, workspace: "1"),
            .focusedMonitorChanged(workspace: "1", monitorId: 1),
            .workspaceChanged(workspace: "1", prevWorkspace: "1"),
            .modeChanged(mode: "main"),
        ])
    }
}

@Suite struct CliAndMiscTests {
    let t = TestHarness()

    @Test func helpAndUnknownSubcommands() {
        #expect(t.run(args: ["workspace", "--help"]) == CommandResult(exitCode: 0, stdout: HelpText.workspace))
        #expect(t.run(args: ["foo"]) == CommandResult(exitCode: 2, stderr: "Unrecognized subcommand 'foo'"))
        #expect(t.run(args: []) == CommandResult(exitCode: 2, stderr: "Can't parse empty string command"))
        #expect(t.run(args: ["move-through", "left"]).exitCode == 2) // Alias of `move`, no window
        #expect(t.run(args: ["workspace", "--foo", "1"]) == CommandResult(exitCode: 2, stderr: "ERROR: Unknown flag '--foo'\nERROR: Argument '(<workspace-name>|next|prev)' is mandatory"))
        #expect(t.run(args: ["resize", "smart", "-50"]).stderr == "resize command doesn't support floating windows yet https://github.com/nikitabobko/AeroSpace/issues/9")
    }

    @Test func windowIdAndWorkspaceEnv() {
        t.window(1, in: t.workspace("a").rootTilingContainer)
        t.window(2, in: t.workspace("b").rootTilingContainer)
        #expect(t.run(args: ["echo", "--", "%{window-id}"], env: CommandEnv(windowId: 2)).stdout == "2")
        // `--focused` is the real focus, regardless of the env (AeroSpace)
        t.focus(t.world.window(byId: 1)!)
        #expect(t.run(args: ["list-windows", "--focused", "--format", "%{window-id}"], env: CommandEnv(windowId: 2)).stdout == "1")
        #expect(t.run(args: ["echo", "--", "%{workspace}"], env: CommandEnv(workspace: "b")).stdout == "b")
        #expect(t.run(args: ["echo", "--window-id", "1", "--", "%{workspace}"], env: CommandEnv(workspace: "b")).stdout == "a")
    }

    @Test func monitorCommands() {
        let right = Monitor(id: "R", name: "Right", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080), isMain: false)
        let t = TestHarness(monitors: [testMonitor, right])
        let leftWorkspace = t.world.activeWorkspace(on: testMonitor)
        let rightWorkspace = t.world.activeWorkspace(on: right)
        t.focus(t.window(1, in: leftWorkspace.rootTilingContainer))
        t.window(2, in: rightWorkspace.rootTilingContainer)

        #expect(t.run("focus-monitor right").exitCode == 0)
        #expect(t.manager.focusedWorkspace == rightWorkspace.name)
        #expect(t.run("focus-monitor right") == CommandResult(exitCode: 2, stderr: "No monitors in direction right"))
        #expect(t.run("focus-monitor --wrap-around next").exitCode == 0)
        #expect(t.manager.focusedWorkspace == leftWorkspace.name)
        #expect(t.run("focus-monitor 'Right'").exitCode == 0)
        #expect(t.run("focus-monitor nothing") == CommandResult(exitCode: 2, stderr: "None of the monitors match the pattern(s)"))
        #expect(t.run("focus-monitor secondary").exitCode == 0)
        #expect(t.manager.focusedWorkspace == rightWorkspace.name)

        t.focus(t.world.window(byId: 1)!)
        #expect(t.run("move-node-to-monitor --focus-follows-window right").exitCode == 0)
        #expect(rightWorkspace.rootTilingContainer.layoutDescription == .h_tiles([.window(1), .window(2)]))
        #expect(t.manager.focusedWindow == 1)
        #expect(t.run("move-node-to-monitor --fail-if-noop 2").exitCode == 2)
        #expect(parseSingle("move-node-to-monitor -- main 2", as: MoveNodeToMonitorCommand.self)?.target == .patterns([.main, .sequenceNumber(2)]))
        #expect(parseSingle("move-node-to-monitor -- next", as: MoveNodeToMonitorCommand.self)?.target == .patterns([.nameRegex("next")]))
        #expect(parseScript("move-node-to-monitor --fail-if-noop left").errorOrNil == "--fail-if-noop is incompatible with (left|down|up|right|next|prev)")
        #expect(parseScript("move-workspace-to-monitor --").errorOrNil == "ERROR: Argument '(left|down|up|right|next|prev|<monitor-pattern>)' is mandatory")
        #expect(parseScript("focus-monitor --wrap-around main").errorOrNil == "--wrap-around is incompatible with <monitor-pattern> argument")
        #expect(parseScript("focus-monitor 0").errorOrNil == "ERROR: Monitor sequence numbers uses 1-based indexing. Values less than 1 are illegal")

        // summon-workspace pulls a workspace to the focused monitor
        t.window(3, in: t.workspace("S").rootTilingContainer)
        #expect(t.run("summon-workspace S").exitCode == 0)
        #expect(t.world.activeWorkspace(on: right).name == "S")
        #expect(t.run("summon-workspace S") == CommandResult(exitCode: 0, stderr: "Workspace 'S' is already visible on the focused monitor. Tip: use --fail-if-noop to exit with non-zero code"))
        t.run("focus-monitor left")
        #expect(t.run("summon-workspace S").exitCode == 0)
        #expect(t.world.activeWorkspace(on: testMonitor).name == "S")
        #expect(t.world.activeWorkspace(on: right).name != "S")
        #expect(parseScript("summon-workspace").errorOrNil == "ERROR: Argument '<workspace>' is mandatory")
        #expect(parseScript("summon-workspace -- --fail-if-noop").errorOrNil == "ERROR: Workspace names starting with dash are disallowed")
    }

    @Test func macosNativeCommands() {
        t.detect(1)
        #expect(t.run("macos-native-fullscreen").exitCode == 0)
        #expect(t.platform.nativeFullscreen.map(\.1) == [true])
        #expect(t.world.window(byId: 1)?.parent is MacosFullscreenWindowsContainer)
        t.manager.windowFullscreenChanged(1, isFullscreen: true)
        #expect(t.run("macos-native-fullscreen on") == CommandResult(exitCode: 0, stderr: "Already fullscreen. Tip: use --fail-if-noop to exit with non-zero exit code"))
        #expect(t.run("macos-native-fullscreen off").exitCode == 0)
        t.manager.windowFullscreenChanged(1, isFullscreen: false)
        #expect(t.world.window(byId: 1)?.parent is TilingContainer)

        #expect(t.run("macos-native-minimize").exitCode == 0)
        #expect(t.platform.minimized.map(\.0) == [1])
        #expect(t.world.window(byId: 1)?.parent is MacosMinimizedWindowsContainer)
        #expect(t.run("macos-native-minimize --window-id 1") == CommandResult(exitCode: 2, stderr: "Window 1 doesn't belong to any monitor. And thus can't even define a focused workspace"))
    }

    @Test func volume() {
        #expect(t.run("volume up").exitCode == 0)
        #expect(t.platform.volumeState == VolumeState(level: 0.5625, isMuted: false))
        #expect(t.platform.volumeHUDShown)
        t.run("volume mute-toggle --no-gui")
        #expect(t.platform.volumeState?.isMuted == true)
        #expect(!t.platform.volumeHUDShown)
        t.run("volume set 0")
        #expect(t.platform.volumeState == VolumeState(level: 0, isMuted: true))
        #expect(parseScript("volume set 101").errorOrNil == "ERROR: 101 must be in range from 0 to 100")
        #expect(parseScript("volume set").errorOrNil == "ERROR: set argument must be followed by <number>")
        #expect(parseScript("volume loud").errorOrNil == "ERROR: Unknown argument 'loud'. Possible values: (up|down|mute-toggle|mute-on|mute-off|set)")
    }

    @Test func reloadConfig() {
        var newConfig = testConfig()
        newConfig.modes["main"] = mode("main", binding("alt-x", "workspace x"))
        newConfig.persistentWorkspaces = ["P"]
        t.platform.reloadResult = ConfigLoadResult(config: newConfig, url: URL(fileURLWithPath: "/c.toml"), diagnostics: [ConfigDiagnostic(.warning, "gaps", "deprecated")], isFatal: false)
        #expect(t.run("reload-config --dry-run") == CommandResult(exitCode: 0, stderr: "[WARNING] gaps: deprecated"))
        #expect(t.manager.activeBindings.isEmpty)
        #expect(t.run("reload-config --warnings-as-errors") == CommandResult(exitCode: 2, stdout: "[WARNING] gaps: deprecated"))
        #expect(t.delegate.configMessages.last == "Parsed '/c.toml' with 1 warning(s). Feel free to close this window.\n\n[WARNING] gaps: deprecated")
        #expect(t.manager.activeBindings.map(\.descriptor) == ["alt-x"])
        #expect(t.world.allWorkspaces.map(\.name).contains("P"))
        #expect(t.manager.config.persistentWorkspaces == ["P"])

        var broken = testConfig()
        broken.modes["main"] = mode("main", binding("alt-y", "workspace"))
        t.platform.reloadResult = ConfigLoadResult(config: broken, url: URL(fileURLWithPath: "/c.toml"), diagnostics: [], isFatal: false)
        let result = t.run("reload-config")
        #expect(result == CommandResult(exitCode: 2, stdout: "[ERROR] mode.main.binding.alt-y: ERROR: Argument '(<workspace-name>|next|prev)' is mandatory"))
        #expect(t.delegate.configMessages.last??.hasPrefix("Failed to parse '/c.toml'. 1 error(s). 0 warning(s)") == true)

        t.platform.reloadResult = ConfigLoadResult(config: Config(), url: nil, diagnostics: [ConfigDiagnostic(.error, "", "TOML syntax")], isFatal: true)
        #expect(t.run("reload-config --no-gui").exitCode == 2)
        #expect(t.manager.config == broken) // Fatal: the current config stays
    }

    @Test func menuBarAndTerminationFrames() {
        let right = Monitor(id: "R", name: "Right", frame: CGRect(x: 1920, y: 0, width: 1000, height: 1000), visibleFrame: CGRect(x: 1920, y: 25, width: 1000, height: 975), isMain: false)
        let t = TestHarness(monitors: [testMonitor, right])
        t.window(1, in: t.world.activeWorkspace(on: testMonitor).rootTilingContainer, appName: "Safari", frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        t.window(2, in: t.world.activeWorkspace(on: right).rootTilingContainer, appName: "Ghostty", frame: CGRect(x: 2000, y: 100, width: 400, height: 300))
        let model = t.manager.menuBarModel()
        #expect(model.text == "*1 │ 2")
        #expect(model.visibleWorkspaces == ["1", "2"])
        #expect(model.workspaces.map(\.suffix) == [" - Safari", " - Ghostty"])
        #expect(t.delegate.menuBarChanges >= 1)
        let frames = t.manager.terminationFrames()
        #expect(frames[2] == CGRect(x: 1920 + 300, y: 25 + 337.5, width: 400, height: 300))
    }
}
