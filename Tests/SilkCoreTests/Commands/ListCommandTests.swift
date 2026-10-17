import CoreGraphics
import Foundation
import SilkConfig
import Testing
@testable import SilkCore

private func aeroSpaceJSON(_ value: some Encodable) -> String {
    JSONEncoder.aeroSpace.encodeToString(value)!
}

@Suite struct ListWindowsTests {
    let t = TestHarness()

    @Test func parse() {
        #expect(parseScript("list-windows --pid 1").errorOrNil == "Mandatory option is not specified (--focused|--all|--monitor|--workspace)")
        #expect(parseScript("list-windows --workspace M --pid 1").errorOrNil == nil)
        #expect(parseScript("list-windows --pid 1 --focused").errorOrNil == "--focused conflicts with other \"filtering\" flags")
        #expect(parseScript("list-windows --pid 1 --all").errorOrNil == "--all conflicts with \"filtering\" flags. Please use '--monitor all' instead of '--all' alias")
        #expect(parseScript("list-windows --all").errorOrNil == nil)
        #expect(parseScript("list-windows --all --workspace M").errorOrNil == "ERROR: Conflicting options: --all, --workspace")
        #expect(parseScript("list-windows --all --focused").errorOrNil == "ERROR: Conflicting options: --all, --focused")
        #expect(parseScript("list-windows --all --count --format %{window-title}").errorOrNil == "ERROR: Conflicting options: --count, --format")
        #expect(parseScript("list-windows --all --focused --monitor mouse").errorOrNil == "ERROR: Conflicting options: --all, --focused")
        #expect(parseScript("list-windows --all --focused --monitor mouse --workspace focused").errorOrNil == "ERROR: Conflicting options: --all, --focused, --workspace")
        #expect(parseScript("list-windows --monitor mouse").errorOrNil == nil)
        #expect(parseScript("list-windows --all --count --json").errorOrNil == "ERROR: Conflicting options: --count, --json")
        #expect(parseScript("list-windows --all --format '%{right-padding}' --json").errorOrNil == "%{right-padding} interpolation variable is not allowed when --json is used")
        #expect(parseScript("list-windows --all --format '%{window-title} |' --json").errorOrNil == "Only interpolation variables and spaces are allowed in '--format' when '--json' is used")
        #expect(parseScript("list-windows --all --format '%{window-title}' --json").errorOrNil == nil)
        #expect(parseScript("list-windows --app-id com.foo --monitor all").errorOrNil == nil)
        #expect(parseScript("list-windows --monitor foo").errorOrNil == "ERROR: Can't parse monitor ID 'foo'. <monitor> possible values: (<monitor-id>|focused|mouse|all)")
        #expect(parseScript("list-windows --all --format").errorOrNil?.hasPrefix("ERROR: <output-format> is mandatory. Possible values:\n         window-id\n") == true)
        #expect(parseScript("list-windows --all --format %{foo}").errorOrNil?.hasPrefix("ERROR: Failed to parse <output-format>. Can't parse 'foo'.") == true)
    }

    @Test func focused() {
        #expect(t.run("list-windows --focused --format '%{window-id}'") == CommandResult(exitCode: 2, stderr: noWindowIsFocused))
        let root = t.workspace("a").rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        #expect(t.run("list-windows --focused --format '%{window-id}'") == CommandResult(exitCode: 0, stdout: "1"))
    }

    @Test func allCountAndJSON() {
        t.window(1, in: t.workspace("a").rootTilingContainer)
        t.window(2, in: t.workspace("a").rootTilingContainer)
        t.window(3, in: t.workspace("b").rootTilingContainer)
        #expect(t.run("list-windows --all --format '%{window-id}'").stdout.split(separator: "\n").sorted() == ["1", "2", "3"])
        #expect(t.run("list-windows --all --count").stdout == "3")
        #expect(t.run("list-windows --workspace b --format '%{window-id}' --json").stdout == aeroSpaceJSON([["window-id": 3]]))
    }

    @Test func defaultFormatIsAPaddedTableSortedByAppAndTitle() {
        let root = t.workspace("a").rootTilingContainer
        t.window(10, in: root, appName: "Safari", title: "GitHub")
        t.window(2, in: root, appName: "Ghostty", title: "zsh")
        t.window(300, in: root, appName: "Safari", title: "Apple")
        #expect(t.run("list-windows --all").stdout == """
            2   | Ghostty | zsh
            300 | Safari  | Apple
            10  | Safari  | GitHub
            """)
        // --json with the default format drops %{right-padding}
        #expect(t.run("list-windows --all --json").stdout == aeroSpaceJSON([
            ["app-name": Primitive.string("Ghostty"), "window-id": .int(2), "window-title": .string("zsh")],
            ["app-name": .string("Safari"), "window-id": .int(300), "window-title": .string("Apple")],
            ["app-name": .string("Safari"), "window-id": .int(10), "window-title": .string("GitHub")],
        ]))
    }

    @Test func slackPlacementScriptFormat() {
        // ~/.slack-placement.sh: `aerospace list-windows --all --format '%{window-id}|%{app-bundle-id}'`
        t.window(5, in: t.workspace("1").rootTilingContainer, bundleId: "com.tinyspeck.slackmacgap", appName: "Slack")
        t.window(7, in: t.workspace("2").rootTilingContainer, bundleId: "com.mitchellh.ghostty", appName: "Ghostty")
        t.window(8, in: t.workspace("2").rootTilingContainer, bundleId: nil, appName: nil)
        let result = t.run(args: ["list-windows", "--all", "--format", "%{window-id}|%{app-bundle-id}"])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "8|NULL-APP-BUNDLE-ID\n7|com.mitchellh.ghostty\n5|com.tinyspeck.slackmacgap")
    }

    @Test func filters() {
        t.window(1, in: t.workspace("a").rootTilingContainer, pid: 10, bundleId: "com.one")
        t.window(2, in: t.workspace("a").rootTilingContainer, pid: 20, bundleId: "com.two")
        t.window(3, in: t.workspace("b").rootTilingContainer, pid: 20, bundleId: "com.two")
        t.world.focusWorkspace(t.workspace("a"))
        #expect(t.run("list-windows --workspace a --pid 20 --format %{window-id}").stdout == "2")
        #expect(t.run("list-windows --monitor all --app-bundle-id com.two --format %{window-id}").stdout.split(separator: "\n").sorted() == ["2", "3"])
        #expect(t.run("list-windows --workspace focused --format %{window-id}").stdout.split(separator: "\n").sorted() == ["1", "2"])
        #expect(t.run("list-windows --workspace visible --count").stdout == "2")
        #expect(t.run("list-windows --monitor 2 --count") == CommandResult(exitCode: 2, stderr: "Invalid monitor ID: 2"))
    }

    @Test func windowFormatVariables() {
        let workspace = t.workspace("ws")
        t.focus(t.window(1, in: workspace.rootTilingContainer, pid: 42, bundleId: "com.app", appName: "App", title: "Title"))
        t.window(2, in: workspace.floatingWindowsContainer)
        t.platform.apps = [AppInfo(pid: 42, bundleId: "com.app", name: "App", execPath: "/Applications/App.app/Contents/MacOS/App", bundlePath: "/Applications/App.app")]
        let format = "%{window-id}%{tab}%{window-title}%{tab}%{window-layout}%{tab}%{window-is-fullscreen}%{tab}%{workspace}%{tab}%{workspace-is-focused}%{tab}%{workspace-is-visible}%{tab}%{workspace-root-container-layout}%{tab}%{app-pid}%{tab}%{app-exec-path}%{tab}%{app-bundle-path}%{tab}%{monitor-id}%{tab}%{monitor-name}%{tab}%{monitor-is-main}%{tab}%{monitor-appkit-nsscreen-screens-id}"
        #expect(t.run(args: ["list-windows", "--focused", "--format", format]).stdout
            == "1\tTitle\th_tiles\tfalse\tws\ttrue\ttrue\th_tiles\t42\t/Applications/App.app/Contents/MacOS/App\t/Applications/App.app\t1\tTest Monitor\ttrue\t1")
        #expect(t.run(args: ["list-windows", "--workspace", "ws", "--format", "%{window-id} %{window-parent-container-layout} %{app-exec-path}"]).stdout
            == "1 h_tiles /Applications/App.app/Contents/MacOS/App\n2 floating NULL-APP-EXEC-PATH")
    }
}

@Suite struct ListWorkspacesTests {
    let t = TestHarness()

    @Test func parse() {
        #expect(parseScript("list-workspaces --all").cmdOrNil != nil)
        #expect(parseScript("list-workspaces --all --visible").cmdOrNil == nil)
        #expect(parseScript("list-workspaces --focused --visible").cmdOrNil == nil)
        #expect(parseScript("list-workspaces --focused --all").cmdOrNil == nil)
        #expect(parseScript("list-workspaces --visible").cmdOrNil == nil)
        #expect(parseScript("list-workspaces --visible --monitor 2").cmdOrNil != nil)
        #expect(parseScript("list-workspaces --monitor focused").cmdOrNil != nil)
        #expect(parseScript("list-workspaces --focused --monitor 2").cmdOrNil == nil)
        #expect(parseScript("list-workspaces --all --format %{workspace}").cmdOrNil != nil)
        #expect(parseScript("list-workspaces --all --format %{workspace} --count").errorOrNil == "ERROR: Conflicting options: --count, --format")
        #expect(parseScript("list-workspaces --empty").errorOrNil == "Mandatory option is not specified (--all|--focused|--monitor)")
        #expect(parseScript("list-workspaces --all --focused --monitor mouse").errorOrNil == "ERROR: Conflicting options: --all, --focused, --monitor")
    }

    @Test func run() {
        t.window(1, in: t.workspace("a").rootTilingContainer)
        t.window(2, in: t.workspace("b").rootTilingContainer)
        t.window(3, in: t.workspace("10").rootTilingContainer)
        t.window(4, in: t.workspace("2").rootTilingContainer)
        #expect(t.run("list-workspaces --all").stdout == "1\n2\n10\na\nb")
        #expect(t.run("list-workspaces --monitor all --visible").stdout == "1")
        #expect(t.run("list-workspaces --monitor all --visible no").stdout == "2\n10\na\nb")
        #expect(t.run("list-workspaces --monitor all --empty").stdout == "1")
        #expect(t.run("list-workspaces --monitor all --empty no").stdout == "2\n10\na\nb")
        #expect(t.run("list-workspaces --focused").stdout == "1")
        #expect(t.run("list-workspaces --monitor focused --count").stdout == "5")
        #expect(t.run("list-workspaces --monitor 99") == CommandResult(exitCode: 2, stderr: "Invalid monitor ID: 99"))
        #expect(t.run("list-workspaces --all --format '%{workspace}' --json").stdout == aeroSpaceJSON([
            ["workspace": "1"], ["workspace": "2"], ["workspace": "10"], ["workspace": "a"], ["workspace": "b"],
        ]))
        #expect(t.run("list-workspaces --focused --format '%{workspace}%{right-padding} | %{monitor-name}'").stdout == "1 | Test Monitor")
    }
}

@Suite struct ListMonitorsModesAppsTests {
    let left = Monitor(id: "L", name: "DELL U2723QE", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), visibleFrame: CGRect(x: 0, y: 25, width: 2560, height: 1415), isMain: true)
    let laptop = Monitor(id: "B", name: "Built-in Retina Display", frame: CGRect(x: 2560, y: 400, width: 1512, height: 982), visibleFrame: CGRect(x: 2560, y: 400, width: 1512, height: 950), isMain: false)

    @Test func listMonitors() {
        let t = TestHarness(monitors: [laptop, left])
        #expect(parseScript("list-monitors --format %{monitor-id} --count").errorOrNil == "ERROR: Conflicting options: --count, --format")
        #expect(t.run("list-monitors").stdout == "1 | DELL U2723QE\n2 | Built-in Retina Display")
        #expect(t.run("list-monitors --count").stdout == "2")
        // AeroSpace focuses the first workspace at startup: "1", the stub of the first monitor in NSScreen order
        #expect(t.run("list-monitors --focused --format %{monitor-name}").stdout == "Built-in Retina Display")
        #expect(t.run("list-monitors --focused no --format %{monitor-name}").stdout == "DELL U2723QE")
        t.platform.mouseLocation = CGPoint(x: 3000, y: 600)
        #expect(t.run("list-monitors --mouse --format %{monitor-id}").stdout == "2")
        #expect(t.run("list-monitors --format '%{monitor-name} %{monitor-appkit-nsscreen-screens-id} %{monitor-is-main}'").stdout
            == "DELL U2723QE 2 true\nBuilt-in Retina Display 1 false")
        #expect(t.run("list-monitors --json").stdout == aeroSpaceJSON([
            ["monitor-id": Primitive.int(1), "monitor-name": .string("DELL U2723QE")],
            ["monitor-id": .int(2), "monitor-name": .string("Built-in Retina Display")],
        ]))
    }

    @Test func listModes() {
        var config = testConfig()
        config.modes = ["main": Mode(name: "main"), "service": Mode(name: "service"), "resize": Mode(name: "resize")]
        let t = TestHarness(config: config)
        #expect(parseScript("list-modes --json --count").errorOrNil == "ERROR: Conflicting options: --count, --json")
        #expect(parseScript("list-modes --current --count").errorOrNil == "ERROR: Conflicting options: --count, --current")
        #expect(t.run("list-modes") == CommandResult(exitCode: 0, stdout: "main\nresize\nservice"))
        #expect(t.run("list-modes --current").stdout == "main")
        #expect(t.run("list-modes --count").stdout == "3")
        #expect(t.run("list-modes --json").stdout == aeroSpaceJSON([["mode-id": "main"], ["mode-id": "resize"], ["mode-id": "service"]]))
        t.run("mode service")
        #expect(t.run("list-modes --current --json").stdout == aeroSpaceJSON([["mode-id": "service"]]))
    }

    @Test func listApps() {
        let t = TestHarness()
        #expect(parseScript("list-apps --macos-native-hidden").cmdOrNil != nil)
        #expect(parseScript("list-apps --macos-native-hidden no").cmdOrNil != nil)
        #expect(parseScript("list-apps --format %{app-bundle-id} --count").errorOrNil == "ERROR: Conflicting options: --count, --format")
        t.platform.apps = [
            AppInfo(pid: 501, bundleId: "com.apple.Safari", name: "Safari"),
            AppInfo(pid: 77, bundleId: nil, name: "Helper", isHidden: true),
        ]
        #expect(t.run("list-apps").stdout == "501 | com.apple.Safari   | Safari\n77  | NULL-APP-BUNDLE-ID | Helper")
        #expect(t.run("list-apps --macos-native-hidden --format %{app-name}").stdout == "Helper")
        #expect(t.run("list-apps --macos-native-hidden no --count").stdout == "1")
    }

    @Test func listExecEnvVars() {
        var config = testConfig()
        config.exec.env = ["PATH": "/opt/homebrew/bin:${PATH}", "FOO": "bar"]
        let t = TestHarness(config: config)
        #expect(t.run("list-exec-env-vars").stdout == "FOO=bar\nHOME=/Users/test\nPATH=/opt/homebrew/bin:")
    }
}
