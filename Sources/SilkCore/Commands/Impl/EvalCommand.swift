struct EvalCommand: ParsableCommand {
    static let kind = CommandKind.eval
    static let help = HelpText.eval
    static let parser = ArgParser<Self>(
        flags: ["--stdin": .stdin],
        positional: [
            .dashDash(mandatory: false),
            .mandatory(\.shellExpr, placeholder: "<aerospace-shell-expr>", consumeStringArg),
        ]
    )

    var common: CommonArgs
    var shellExpr = ""
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        switch CommandRegistry.parse(script: shellExpr, allowExecAndForget: false, allowEval: false) {
            case .failure(let failure):
                context.io.err(failure.message)
                return failure.exitCode
            case .help:
                return context.io.fail("--help is not supported inside eval command")
            case .cmd(let shell):
                return context.world.run(shell, env: context.env, io: context.io)
        }
    }
}
