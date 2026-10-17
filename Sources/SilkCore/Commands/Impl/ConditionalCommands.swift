struct TrueCommand: ParsableCommand {
    static let kind = CommandKind._true
    static let help = HelpText._true
    static let parser = ArgParser<Self>(flags: [:], positional: [])

    var common: CommonArgs
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 { ExitCode.success }
}

struct FalseCommand: ParsableCommand {
    static let kind = CommandKind._false
    static let help = HelpText._false
    static let parser = ArgParser<Self>(flags: [:], positional: [])

    var common: CommonArgs
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 { ExitCode.conditionalFalse }
}
