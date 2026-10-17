struct MoveNodeToWorkspaceCommand: ParsableCommand {
    static let kind = CommandKind.moveNodeToWorkspace
    static let help = HelpText.moveNodeToWorkspace
    static let parser = ArgParser<Self>(
        flags: [
            "--wrap-around": .constant(\.wrapAroundFlag, true),
            "--fail-if-noop": .trueBool(\.failIfNoop),
            "--window-id": .windowId,
            "--focus-follows-window": .trueBool(\.focusFollowsWindow),
            "--stdin": .stdin,
            "--no-stdin": .noStdin,
        ],
        positional: [
            .dashDash(mandatory: false),
            .mandatory(\.target, placeholder: WorkspaceTarget.placeholder, WorkspaceTarget.parse),
        ],
        conflictingOptions: [["--stdin", "--no-stdin"]]
    )

    var common: CommonArgs
    var wrapAroundFlag: Bool?
    var failIfNoop = false
    var focusFollowsWindow = false
    var target = WorkspaceTarget.relative(.next)
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    static func parse(_ args: [String]) -> ParsedCmd<MoveNodeToWorkspaceCommand> {
        parseArgs(args)
            .filter("--wrapAround requires using (prev|next) argument") { ($0.wrapAroundFlag != nil).implies($0.target.isRelative) }
            .filterNot("--fail-if-noop is incompatible with (next|prev)") { $0.failIfNoop && $0.target.isRelative }
            .filterNot("--window-id is incompatible with (next|prev)") { $0.common.windowId != nil && $0.target.isRelative }
            .filter("--stdin and --no-stdin require using \(NextPrev.unionLiteral) argument") {
                ($0.common.explicitStdinFlag != nil).implies($0.target.isRelative)
            }
    }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        guard let focus = context.resolveTarget(common) else { return ExitCode.fail }
        guard let window = focus.window else { return context.io.fail(noWindowIsFocused) }
        let targetWorkspace: Workspace
        switch target {
            case .relative(let nextPrev):
                guard let subjectWorkspace = window.nodeWorkspace else {
                    return context.io.fail("Window \(window.id) doesn't belong to any workspace")
                }
                let stdin = common.explicitStdinFlag == true ? context.io.readStdin() : nil
                switch world.nextPrevWorkspace(current: subjectWorkspace, isNext: nextPrev == .next, wrapAround: wrapAroundFlag ?? false, stdin: stdin, target: focus) {
                    case .success(let workspace): targetWorkspace = workspace
                    case .failure(let error): return context.io.fail(error.message)
                }
            case .direct(let name):
                targetWorkspace = world.workspace(named: name.raw)
        }
        return moveWindowToWorkspace(window, targetWorkspace, context, focusFollowsWindow: focusFollowsWindow, failIfNoop: failIfNoop)
    }
}

/// Moves the window (keeping it tiling or floating) to `targetWorkspace`.
func moveWindowToWorkspace(
    _ window: Window,
    _ targetWorkspace: Workspace,
    _ context: CommandContext,
    focusFollowsWindow: Bool,
    failIfNoop: Bool,
    index: Int = indexBindLast
) -> Int32 {
    if window.nodeWorkspace === targetWorkspace {
        if failIfNoop { return ExitCode.fail }
        return context.io.succeed(warning: "Window '\(window.id)' already belongs to workspace '\(targetWorkspace.name)'. Tip: use --fail-if-noop to exit with non-zero code")
    }
    let targetContainer: TreeNode = window.isFloating ? targetWorkspace.floatingWindowsContainer : targetWorkspace.rootTilingContainer
    window.bind(to: targetContainer, adaptiveWeight: weightAuto, index: index)
    return ExitCode.from(focusFollowsWindow ? context.world.focusWindow(window) : true)
}
