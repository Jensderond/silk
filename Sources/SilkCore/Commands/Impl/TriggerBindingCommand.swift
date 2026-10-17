struct TriggerBindingCommand: ParsableCommand {
    static let kind = CommandKind.triggerBinding
    static let help = HelpText.triggerBinding
    static let parser = ArgParser<Self>(
        flags: ["--mode": .single(\.mode, "<mode-id>") { .success($0) }],
        positional: [.dashDash(mandatory: false), .mandatory(\.binding, placeholder: "<binding>", consumeStringArg)]
    )

    var common: CommonArgs
    var mode: String?
    var binding = ""
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    static func parse(_ args: [String]) -> ParsedCmd<TriggerBindingCommand> {
        parseArgs(args).filter("--mode flag is mandatory") { $0.mode != nil }
    }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        guard let mode else { return context.io.fail(internalErrorMessage()) }
        guard let modeConfig = world.config.modes[mode] else {
            return context.io.fail("Mode '\(mode)' doesn't exist. Available modes: \(world.config.modes.keys.sorted().joined(separator: ","))")
        }
        guard let found = modeConfig.binding(named: binding), let shell = world.compiledConfig.bindings[mode]?[found.descriptor] else {
            return context.io.fail("Binding '\(binding)' is not presented in mode '\(mode)'")
        }
        return world.run(shell, env: context.env, io: context.io)
    }
}
