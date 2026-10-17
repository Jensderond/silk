import Testing
@testable import SilkCore

@Suite struct WorkspaceCommandTests {
    let t = TestHarness()

    /// Focuses `name` and lets the focus callbacks settle, like AeroSpace's tests do before running a command.
    private func focusWorkspace(_ name: String) {
        #expect(t.world.focusWorkspace(t.workspace(name)))
        t.world.refreshModel()
    }

    @Test func parse() {
        #expect(parseScript("workspace my mail").errorOrNil == "ERROR: Unknown argument 'mail'")
        #expect(parseScript("workspace 'my mail'").errorOrNil == "ERROR: Whitespace characters are forbidden in workspace names")
        #expect(parseScript("workspace").errorOrNil == "ERROR: Argument '(<workspace-name>|next|prev)' is mandatory")
        #expect(parseSingle("workspace next", as: WorkspaceCommand.self)?.target == .relative(.next))
        let autoBackAndForth = parseSingle("workspace --auto-back-and-forth W", as: WorkspaceCommand.self)
        #expect(autoBackAndForth?.target == .direct(try! WorkspaceName.parse("W").get()))
        #expect(autoBackAndForth?.autoBackAndForth == true)
        #expect(parseScript("workspace --wrap-around W").errorOrNil == "--wrapAround requires using (next|prev) argument")
        #expect(parseScript("workspace --auto-back-and-forth next").errorOrNil == "--auto-back-and-forth is incompatible with (next|prev)")
        #expect(parseSingle("workspace next --wrap-around", as: WorkspaceCommand.self)?.wrapAroundFlag == true)
        #expect(parseScript("workspace --stdin foo").errorOrNil == "--stdin and --no-stdin require using (next|prev) argument")
        #expect(parseSingle("workspace --stdin next", as: WorkspaceCommand.self)?.common.explicitStdinFlag == true)
        #expect(parseSingle("workspace --no-stdin next", as: WorkspaceCommand.self)?.common.explicitStdinFlag == false)
        #expect(parseScript("workspace --stdin --no-stdin next").errorOrNil == "ERROR: Conflicting options: --no-stdin, --stdin")
        #expect(parseScript("workspace --fail-if-noop --auto-back-and-forth a").errorOrNil == "--fail-if-noop is incompatible with --auto-back-and-forth")
        #expect(parseScript("workspace focused").errorOrNil == "ERROR: 'focused' is a reserved workspace name")
        #expect(parseScript("workspace _a").errorOrNil == "ERROR: Workspace names starting with underscore are reserved for future use")
        #expect(parseScript("workspace a,b").errorOrNil == "ERROR: Workspace names are not allowed to contain comma")
    }

    @Test func parseDashDash() {
        #expect(parseSingle("workspace -- foo", as: WorkspaceCommand.self)?.target == .direct(try! WorkspaceName.parse("foo").get()))
        #expect(parseScript("workspace -- next").errorOrNil == "ERROR: 'next' is a reserved workspace name")
        #expect(parseScript("workspace --").errorOrNil == "ERROR: Argument '(<workspace-name>|next|prev)' is mandatory")
        #expect(parseSingle("workspace --auto-back-and-forth -- foo", as: WorkspaceCommand.self)?.autoBackAndForth == true)
        #expect(parseScript("workspace -- foo --fail-if-noop").errorOrNil == "ERROR: Unknown argument '--fail-if-noop'")
        #expect(parseScript("workspace -- --help").errorOrNil == "ERROR: Workspace names starting with dash are disallowed")
        #expect(parseScript("workspace --help").isHelp)
    }

    @Test func directFocusesDifferentWorkspace() {
        focusWorkspace("a")
        let result = t.run("workspace b")
        #expect(result == CommandResult(exitCode: 0))
        #expect(t.world.focus.workspace.name == "b")
    }

    @Test func directAlreadyFocused() {
        focusWorkspace("a")
        let result = t.run("workspace a")
        #expect(result == CommandResult(exitCode: 0, stderr: "Workspace 'a' is already focused. Tip: use --fail-if-noop to exit with non-zero code"))
        #expect(t.run("workspace --fail-if-noop a") == CommandResult(exitCode: 2))
        #expect(t.world.focus.workspace.name == "a")
    }

    @Test func autoBackAndForth() {
        t.window(1, in: t.workspace("b").rootTilingContainer) // Keep "b" alive
        focusWorkspace("a")
        t.world.prevFocusedWorkspaceName = "b"
        #expect(t.run("workspace --auto-back-and-forth a").exitCode == 0)
        #expect(t.world.focus.workspace.name == "b")

        t.world.prevFocusedWorkspaceName = "c"
        #expect(t.run("workspace --auto-back-and-forth d").exitCode == 0)
        #expect(t.world.focus.workspace.name == "d")
    }

    @Test func autoBackAndForthWithoutPreviousFails() {
        focusWorkspace("a")
        t.world.prevFocusedWorkspaceName = nil
        #expect(t.run("workspace --auto-back-and-forth a").exitCode == 2)
        #expect(t.world.focus.workspace.name == "a")
    }

    @Test(arguments: [
        ("a", "--stdin next", 0, "b"),
        ("b", "--stdin prev", 0, "a"),
        ("c", "--wrap-around --stdin next", 0, "a"),
        ("a", "--wrap-around --stdin prev", 0, "c"),
        ("c", "--stdin next", 2, "c"),
        ("a", "--stdin prev", 2, "a"),
        ("z", "--stdin next", 0, "a"), // Current not in the list: index 0
    ])
    func relativeWithStdin(focused: String, args: String, exitCode: Int32, expected: String) {
        focusWorkspace(focused)
        let result = t.run(args: ["workspace"] + args.split(separator: " ").map(String.init), stdin: "a\nb\nc\n")
        #expect(result.exitCode == exitCode)
        #expect(t.world.focus.workspace.name == expected)
    }

    @Test func relativeErrors() {
        focusWorkspace("a")
        #expect(t.run(args: ["workspace", "--stdin", "next"], stdin: "") == CommandResult(exitCode: 2, stderr: "The list of workspaces is empty"))
        #expect(t.run(args: ["workspace", "--stdin", "next"], stdin: "a\n") == CommandResult(exitCode: 2, stderr: "Reached the end of the supplied workspaces list"))
        #expect(t.run(args: ["workspace", "--stdin", "prev"], stdin: "a\n") == CommandResult(exitCode: 2, stderr: "Rached the beginning of the supplied workspaces list"))
    }

    @Test func relativeWithoutStdinUsesWorkspacesOfTheMonitor() {
        t.window(1, in: t.workspace("b").rootTilingContainer)
        t.window(2, in: t.workspace("c").rootTilingContainer)
        focusWorkspace("a")
        #expect(t.run("workspace next").exitCode == 0)
        #expect(t.world.focus.workspace.name == "b")
        t.run("workspace next")
        t.run("workspace next")
        #expect(t.world.focus.workspace.name == "c")
        t.run("workspace --wrap-around next")
        #expect(t.world.focus.workspace.name == "b")
    }

    @Test func workspaceBackAndForth() {
        t.window(1, in: t.workspace("a").rootTilingContainer)
        t.window(2, in: t.workspace("b").rootTilingContainer)
        t.run("workspace a")
        t.run("workspace b")
        t.run("workspace-back-and-forth")
        #expect(t.world.focus.workspace.name == "a")
        t.run("workspace-back-and-forth")
        #expect(t.world.focus.workspace.name == "b")
    }

    @Test func focusBackAndForth() {
        let root = t.workspace("a").rootTilingContainer
        t.window(1, in: root)
        t.window(2, in: root)
        t.run("focus --window-id 1")
        t.run("focus --window-id 2")
        t.run("focus-back-and-forth")
        #expect(t.focusedWindowId == 1)
        t.run("focus-back-and-forth")
        #expect(t.focusedWindowId == 2)
        t.manager.windowDestroyed(1)
        #expect(t.run("focus-back-and-forth") == CommandResult(exitCode: 2, stderr: "Prev window has been closed"))
    }
}

@Suite struct MoveNodeToWorkspaceCommandTests {
    let t = TestHarness()

    @Test func parse() {
        #expect(parseSingle("move-node-to-workspace next", as: MoveNodeToWorkspaceCommand.self)?.target == .relative(.next))
        #expect(parseScript("move-node-to-workspace --fail-if-noop next").errorOrNil == "--fail-if-noop is incompatible with (next|prev)")
        #expect(parseScript("move-node-to-workspace --stdin foo").errorOrNil == "--stdin and --no-stdin require using (next|prev) argument")
        #expect(parseScript("move-node-to-workspace --window-id 1 next").errorOrNil == "--window-id is incompatible with (next|prev)")
        #expect(parseScript("move-node-to-workspace --wrap-around a").errorOrNil == "--wrapAround requires using (prev|next) argument")
        #expect(parseSingle("move-node-to-workspace -- foo", as: MoveNodeToWorkspaceCommand.self)?.target == .direct(try! WorkspaceName.parse("foo").get()))
        #expect(parseScript("move-node-to-workspace -- prev").errorOrNil == "ERROR: 'prev' is a reserved workspace name")
        #expect(parseScript("move-node-to-workspace --").errorOrNil == "ERROR: Argument '(<workspace-name>|next|prev)' is mandatory")
        #expect(parseSingle("move-node-to-workspace --focus-follows-window -- foo", as: MoveNodeToWorkspaceCommand.self)?.focusFollowsWindow == true)
    }

    @Test func simple() {
        let a = t.workspace("a")
        t.focus(t.window(1, in: a.rootTilingContainer))
        t.run("move-node-to-workspace b")
        #expect(a.isEffectivelyEmpty)
        #expect(t.workspace("b").rootTilingContainer.layoutDescription == .h_tiles([.window(1)]))
        #expect(t.world.focus.workspace.name == "a")
    }

    @Test func focusMovesToAnotherWindow() {
        let root = t.workspace("a").rootTilingContainer
        t.window(1, in: root)
        t.focus(t.window(2, in: root))
        t.run("move-node-to-workspace b")
        #expect(t.focusedWindowId == 1)
    }

    @Test func preservesFloatingLayout() {
        let a = t.workspace("a")
        #expect(t.focus(t.window(1, in: a.floatingWindowsContainer)))
        t.run("move-node-to-workspace b")
        #expect(a.isEffectivelyEmpty)
        #expect(t.workspace("b").floatingWindows.map(\.id) == [1])
    }

    @Test func summonWindowById() {
        let a = t.workspace("a")
        t.focus(t.window(1, in: a.rootTilingContainer))
        t.window(2, in: t.workspace("b").rootTilingContainer)
        t.run("move-node-to-workspace --window-id 2 a")
        #expect(t.world.focus.workspace === a)
        #expect(t.focusedWindowId == 1)
        #expect(a.rootTilingContainer.children.count == 2)
    }

    @Test func errorsAndNoops() {
        #expect(t.run("move-node-to-workspace b") == CommandResult(exitCode: 2, stderr: noWindowIsFocused))
        t.focus(t.window(1, in: t.workspace("a").rootTilingContainer))
        #expect(t.run("move-node-to-workspace a") == CommandResult(exitCode: 0, stderr: "Window '1' already belongs to workspace 'a'. Tip: use --fail-if-noop to exit with non-zero code"))
        #expect(t.run("move-node-to-workspace --fail-if-noop a") == CommandResult(exitCode: 2))
    }

    @Test func focusFollowsWindow() {
        let a = t.workspace("a")
        t.focus(t.window(1, in: a.rootTilingContainer))
        t.run("move-node-to-workspace --focus-follows-window b")
        #expect(t.world.focus.workspace.name == "b")
        #expect(t.focusedWindowId == 1)
        #expect(a.isEffectivelyEmpty)
    }

    @Test func relative() {
        t.focus(t.window(1, in: t.workspace("a").rootTilingContainer))
        t.window(2, in: t.workspace("b").rootTilingContainer)
        t.run("move-node-to-workspace next")
        #expect(t.workspace("b").rootTilingContainer.layoutDescription == .h_tiles([.window(2), .window(1)]))

        let other = TestHarness()
        other.focus(other.window(1, in: other.workspace("a").rootTilingContainer))
        #expect(other.run("move-node-to-workspace prev") == CommandResult(exitCode: 2, stderr: "Rached the beginning of the supplied workspaces list"))
        #expect(other.run(args: ["move-node-to-workspace", "--wrap-around", "--stdin", "prev"], stdin: "a\nb\n").exitCode == 0)
        #expect(other.workspace("b").rootTilingContainer.layoutDescription == .h_tiles([.window(1)]))
    }
}

@Suite struct SwapCommandTests {
    let t = TestHarness()

    @Test func directional() {
        let root = t.workspace("a").rootTilingContainer
        let column = t.vTiles(root)
        #expect(t.focus(t.window(1, in: column)))
        t.window(2, in: column)
        t.window(3, in: root)
        let steps: [(String, LayoutDescription)] = [
            ("swap right", .h_tiles([.v_tiles([.window(3), .window(2)]), .window(1)])),
            ("swap left", .h_tiles([.v_tiles([.window(1), .window(2)]), .window(3)])),
            ("swap down", .h_tiles([.v_tiles([.window(2), .window(1)]), .window(3)])),
            ("swap up", .h_tiles([.v_tiles([.window(1), .window(2)]), .window(3)])),
        ]
        for (script, expected) in steps {
            t.run(script)
            #expect(root.layoutDescription == expected, "\(script)")
            #expect(t.focusedWindowId == 1)
            #expect(root.mostRecentWindowRecursive?.id == 1)
        }
    }

    @Test func dfsRelative() {
        let root = t.workspace("a").rootTilingContainer
        let column = t.vTiles(root)
        #expect(t.focus(t.window(1, in: column)))
        t.window(2, in: column)
        t.window(3, in: root)
        let steps: [(String, LayoutDescription)] = [
            ("swap dfs-next", .h_tiles([.v_tiles([.window(2), .window(1)]), .window(3)])),
            ("swap dfs-next", .h_tiles([.v_tiles([.window(2), .window(3)]), .window(1)])),
            ("swap dfs-prev", .h_tiles([.v_tiles([.window(2), .window(1)]), .window(3)])),
            ("swap dfs-prev", .h_tiles([.v_tiles([.window(1), .window(2)]), .window(3)])),
        ]
        for (script, expected) in steps {
            t.run(script)
            #expect(root.layoutDescription == expected, "\(script)")
            #expect(t.focusedWindowId == 1)
        }
    }

    @Test func wrapping() {
        let root = t.workspace("a").rootTilingContainer
        #expect(t.focus(t.window(1, in: root)))
        t.window(2, in: root)
        t.window(3, in: root)
        #expect(t.run("swap left").exitCode == 2)
        t.run("swap --wrap-around left")
        #expect(root.layoutDescription == .h_tiles([.window(3), .window(2), .window(1)]))
        t.run("swap --wrap-around right")
        #expect(root.layoutDescription == .h_tiles([.window(1), .window(2), .window(3)]))
        t.run("swap --wrap-around dfs-prev")
        #expect(root.layoutDescription == .h_tiles([.window(3), .window(2), .window(1)]))
        t.run("swap --wrap-around dfs-next")
        #expect(root.layoutDescription == .h_tiles([.window(1), .window(2), .window(3)]))
    }

    @Test func swapFocus() {
        let root = t.workspace("a").rootTilingContainer
        t.window(1, in: root)
        #expect(t.focus(t.window(2, in: root)))
        t.window(3, in: root)
        t.run("swap --swap-focus right")
        #expect(root.layoutDescription == .h_tiles([.window(1), .window(3), .window(2)]))
        #expect(t.focusedWindowId == 3)
        #expect(root.mostRecentWindowRecursive?.id == 3)
    }
}
