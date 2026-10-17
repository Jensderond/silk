struct FocusBackAndForthCommand: ParsableCommand {
    static let kind = CommandKind.focusBackAndForth
    static let help = HelpText.focusBackAndForth
    static let parser = ArgParser<Self>(flags: [:], positional: [])

    var common: CommonArgs
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        guard let prevFocus = context.world.prevFocusLive else { return context.io.fail("Prev window has been closed") }
        return ExitCode.from(context.world.setFocus(prevFocus))
    }
}
