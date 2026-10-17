struct BalanceSizesCommand: ParsableCommand {
    static let kind = CommandKind.balanceSizes
    static let help = HelpText.balanceSizes
    static let parser = ArgParser<Self>(flags: ["--workspace": .workspace], positional: [])

    var common: CommonArgs
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        guard let target = context.resolveTarget(common) else { return ExitCode.fail }
        balance(target.workspace.rootTilingContainer)
        return ExitCode.success
    }

    private func balance(_ parent: TilingContainer) {
        for child in parent.children {
            if parent.layout == .tiles { child.setWeight(parent.orientation, 1) }
            if let child = child as? TilingContainer { balance(child) }
        }
    }
}
