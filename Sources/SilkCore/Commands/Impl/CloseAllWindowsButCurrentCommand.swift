struct CloseAllWindowsButCurrentCommand: ParsableCommand {
    static let kind = CommandKind.closeAllWindowsButCurrent
    static let help = HelpText.closeAllWindowsButCurrent
    static let parser = ArgParser<Self>(flags: ["--quit-if-last-window": .trueBool(\.quitIfLastWindow)], positional: [])

    var common: CommonArgs
    var quitIfLastWindow = false
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        guard let target = context.resolveTarget(common) else { return ExitCode.fail }
        guard let focused = target.window else { return context.io.fail("Empty workspace") }
        guard let workspace = focused.nodeWorkspace else {
            return context.io.fail("Focused window '\(focused.id)' doesn't belong to workspace")
        }
        var close = CloseCommand(rawArgs: [])
        close.quitIfLastWindow = quitIfLastWindow
        var result = ExitCode.success
        for window in workspace.allLeafWindowsRecursive where window !== focused {
            let exitCode = close.run(context.with(env: context.env.withWindowId(window.id)))
            result = exitCode == ExitCode.success ? result : exitCode
        }
        return result
    }
}
