struct WorkspaceBackAndForthCommand: ParsableCommand {
    static let kind = CommandKind.workspaceBackAndForth
    static let help = HelpText.workspaceBackAndForth
    static let parser = ArgParser<Self>(flags: [:], positional: [])

    var common: CommonArgs
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        guard let workspace = context.world.prevFocusedWorkspace else { return ExitCode.fail }
        // AeroSpace succeeds whenever there is a previous workspace, even if it can't be shown
        context.world.focusWorkspace(workspace)
        return ExitCode.success
    }
}
