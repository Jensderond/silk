struct MoveWorkspaceToMonitorCommand: ParsableCommand {
    static let kind = CommandKind.moveWorkspaceToMonitor
    static let help = HelpText.moveWorkspaceToMonitor
    static let parser = ArgParser<Self>(
        flags: [
            "--wrap-around": .trueBool(\.wrapAround),
            "--workspace": .workspace,
        ],
        positional: [
            .dashDash(mandatory: false),
            .mandatory(\.target, placeholder: MonitorTarget.cases.joinedCliArgs, MonitorTarget.parse),
        ]
    )

    var common: CommonArgs
    var wrapAround = false
    var target = MonitorTarget.relative(.next)
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    static func parse(_ args: [String]) -> ParsedCmd<MoveWorkspaceToMonitorCommand> {
        parseArgs(args).filter("--wrap-around is incompatible with <monitor-pattern> argument") { $0.wrapAround.implies(!$0.target.isPatterns) }
    }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        guard let focus = context.resolveTarget(common) else { return ExitCode.fail }
        let workspace = focus.workspace
        let previousMonitor = world.monitor(of: workspace)
        switch world.resolve(target, from: previousMonitor, wrapAround: wrapAround) {
            case .success(let targetMonitor):
                if world.monitorId1Based(targetMonitor) == world.monitorId1Based(previousMonitor) { return ExitCode.success }
                guard world.setActiveWorkspace(workspace, on: targetMonitor) else {
                    return context.io.fail("Can't move workspace '\(workspace.name)' to monitor '\(targetMonitor.name)'. workspace-to-monitor-force-assignment doesn't allow it")
                }
                world.setActiveWorkspace(world.stubWorkspace(for: previousMonitor), on: previousMonitor)
                return ExitCode.success
            case .failure(let error):
                return context.io.fail(error.message)
        }
    }
}
