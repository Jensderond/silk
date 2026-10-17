struct MoveNodeToMonitorCommand: ParsableCommand {
    static let kind = CommandKind.moveNodeToMonitor
    static let help = HelpText.moveNodeToMonitor
    static let parser = ArgParser<Self>(
        flags: [
            "--wrap-around": .trueBool(\.wrapAround),
            "--window-id": .windowId,
            "--focus-follows-window": .trueBool(\.focusFollowsWindow),
            "--fail-if-noop": .trueBool(\.failIfNoop),
        ],
        positional: [
            .dashDash(mandatory: false),
            .mandatory(\.target, placeholder: MonitorTarget.cases.joinedCliArgs, MonitorTarget.parse),
        ]
    )

    var common: CommonArgs
    var failIfNoop = false
    var focusFollowsWindow = false
    var wrapAround = false
    var target = MonitorTarget.relative(.next)
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    static func parse(_ args: [String]) -> ParsedCmd<MoveNodeToMonitorCommand> {
        parseArgs(args)
            .filter("--wrap-around is incompatible with <monitor-pattern> argument") { $0.wrapAround.implies(!$0.target.isPatterns) }
            .filter("--fail-if-noop is incompatible with \(MonitorTarget.casesExceptPatterns.joinedCliArgs)") { $0.failIfNoop.implies($0.target.isPatterns) }
    }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        guard let focus = context.resolveTarget(common) else { return ExitCode.fail }
        guard let window = focus.window else { return context.io.fail(noWindowIsFocused) }
        guard let workspace = window.nodeWorkspace else { return context.io.fail(windowIsntPartOfTree(window)) }
        switch world.resolve(target, from: world.monitor(of: workspace), wrapAround: wrapAround) {
            case .success(let targetMonitor):
                let targetWorkspace = world.activeWorkspace(on: targetMonitor)
                let insertFirst = target.directionOrNil.map { direction in
                    direction.isPositive && targetWorkspace.rootTilingContainer.orientation == direction.orientation
                } ?? false
                return moveWindowToWorkspace(
                    window,
                    targetWorkspace,
                    context,
                    focusFollowsWindow: focusFollowsWindow,
                    failIfNoop: failIfNoop,
                    index: insertFirst ? 0 : indexBindLast
                )
            case .failure(let error):
                return context.io.fail(error.message)
        }
    }
}
