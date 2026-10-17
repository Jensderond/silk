struct EchoCommand: ParsableCommand {
    static let kind = CommandKind.echo
    static let help = HelpText.echo
    static let parser = ArgParser<Self>(
        flags: [
            "--stderr": .trueBool(\.isStderr),
            "--window-id": .windowId,
        ],
        positional: [
            .dashDash(mandatory: true),
            .mandatory(\.args, placeholder: "<string>") { input in
                let args = Array(input.args[input.index...])
                var result: [FormatTokens] = []
                for arg in args {
                    switch arg.interpolationTokens(interpolationChar: "%", of: InterVar.self) {
                        case .success(let tokens): result.append(tokens)
                        case .failure(let error): return ParsedArg(value: .failure(error), advanceBy: args.count)
                    }
                }
                return .success(result, advanceBy: args.count)
            },
        ]
    )

    var common: CommonArgs
    var args: [FormatTokens] = []
    var isStderr = false
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        let io = context.io
        guard let target = context.resolveTarget(common) else { return ExitCode.fail }
        let object: AeroObj = target.window.map { .window($0, title: $0.title) } ?? .workspace(target.workspace)
        let formatter = Formatter(world: context.world)
        for arg in args {
            switch formatter.format([object], arg) {
                case .success(let lines):
                    for line in lines {
                        if isStderr { io.err(line) } else { io.out(line) }
                    }
                case .failure(let failure):
                    for error in failure.errors {
                        if case .unknownInterpolationVariable = error { io.err(noWindowIsFocused) } else { io.err(error.description) }
                    }
                    return ExitCode.fail
            }
        }
        return ExitCode.success
    }
}
