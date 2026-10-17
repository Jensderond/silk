struct EnableCommand: ParsableCommand {
    enum State: String, CaseIterable {
        case on, off, toggle
    }

    static let kind = CommandKind.enable
    static let help = HelpText.enable
    static let parser = ArgParser<Self>(
        flags: ["--fail-if-noop": .trueBool(\.failIfNoop)],
        positional: [.mandatory(\.targetState, placeholder: State.unionLiteral, parseEnumArg(State.self))]
    )

    var common: CommonArgs
    var targetState = State.toggle
    var failIfNoop = false
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    static func parse(_ args: [String]) -> ParsedCmd<EnableCommand> {
        parseArgs(args).filterNot("--fail-if-noop is incompatible with 'toggle' argument") { $0.targetState == .toggle && $0.failIfNoop }
    }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        let previousState = world.isEnabled
        let newState = switch targetState {
            case .on: true
            case .off: false
            case .toggle: !world.isEnabled
        }
        if newState == previousState {
            if failIfNoop { return ExitCode.fail }
            return context.io.succeed(warning: newState
                ? "Already enabled. Tip: use --fail-if-noop to exit with non-zero code"
                : "Already disabled. Tip: use --fail-if-noop to exit with non-zero code")
        }
        world.setEnabled(newState)
        return ExitCode.success
    }
}
