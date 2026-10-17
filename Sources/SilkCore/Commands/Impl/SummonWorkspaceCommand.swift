struct SummonWorkspaceCommand: ParsableCommand {
    static let kind = CommandKind.summonWorkspace
    static let help = HelpText.summonWorkspace
    static let parser = ArgParser<Self>(
        flags: ["--fail-if-noop": .trueBool(\.failIfNoop)],
        positional: [
            .dashDash(mandatory: false),
            .mandatory(\.target, placeholder: "<workspace>") { input in ParsedArg(value: WorkspaceName.parse(input.arg).map(Optional.some), advanceBy: 1) },
        ]
    )

    var common: CommonArgs
    var target: WorkspaceName?
    var failIfNoop = false
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        guard let target else { return context.io.fail(internalErrorMessage()) }
        let workspace = world.workspace(named: target.raw)
        let monitor = world.monitor(of: world.focus.workspace)
        if world.activeWorkspace(on: monitor) === workspace {
            if failIfNoop { return ExitCode.fail }
            return context.io.succeed(warning: "Workspace '\(workspace.name)' is already visible on the focused monitor. Tip: use --fail-if-noop to exit with non-zero code")
        }
        let previousMonitor = world.isVisible(workspace) ? world.monitor(of: workspace) : nil
        guard world.setActiveWorkspace(workspace, on: monitor) else {
            return context.io.fail("Can't move workspace '\(workspace.name)' to monitor '\(monitor.name)'. workspace-to-monitor-force-assignment doesn't allow it")
        }
        if let previousMonitor {
            world.setActiveWorkspace(world.stubWorkspace(for: previousMonitor), on: previousMonitor)
        }
        return ExitCode.from(world.focusWorkspace(workspace))
    }
}
