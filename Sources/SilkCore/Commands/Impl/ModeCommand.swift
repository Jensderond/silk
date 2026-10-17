struct ModeCommand: ParsableCommand {
    static let kind = CommandKind.mode
    static let help = HelpText.mode
    static let parser = ArgParser<Self>(
        flags: [:],
        positional: [.dashDash(mandatory: false), .mandatory(\.targetMode, placeholder: "<binding-mode>", consumeStringArg)]
    )

    var common: CommonArgs
    var targetMode = ""
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        context.world.activateMode(targetMode)
        return ExitCode.success
    }
}
