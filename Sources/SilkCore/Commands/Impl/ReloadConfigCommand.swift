struct ReloadConfigCommand: ParsableCommand {
    static let kind = CommandKind.reloadConfig
    static let help = HelpText.reloadConfig
    static let parser = ArgParser<Self>(
        flags: [
            "--no-gui": .trueBool(\.noGui),
            "--dry-run": .trueBool(\.dryRun),
            "--warnings-as-errors": .trueBool(\.warningsAsErrors),
        ],
        positional: []
    )

    var common: CommonArgs
    var noGui = false
    var dryRun = false
    var warningsAsErrors = false
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        let result = context.world.reloadConfig(noGui: noGui, dryRun: dryRun, warningsAsErrors: warningsAsErrors)
        if !result.stdout.isEmpty { context.io.out(result.stdout) }
        if !result.stderr.isEmpty { context.io.err(result.stderr) }
        return ExitCode.from(result.isOk)
    }
}
