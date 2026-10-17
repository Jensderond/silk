struct ListExecEnvVarsCommand: ParsableCommand {
    static let kind = CommandKind.listExecEnvVars
    static let help = HelpText.listExecEnvVars
    static let parser = ArgParser<Self>(flags: [:], positional: [])

    var common: CommonArgs
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        for (key, value) in context.world.execEnvironment.sorted(by: { $0.key < $1.key }) {
            context.io.out("\(key)=\(value)")
        }
        return ExitCode.success
    }
}
