struct FlattenWorkspaceTreeCommand: ParsableCommand {
    static let kind = CommandKind.flattenWorkspaceTree
    static let help = HelpText.flattenWorkspaceTree
    static let parser = ArgParser<Self>(flags: ["--workspace": .workspace], positional: [])

    var common: CommonArgs
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        guard let target = context.resolveTarget(common) else { return ExitCode.fail }
        let workspace = target.workspace
        for window in workspace.rootTilingContainer.allLeafWindowsRecursive {
            window.bind(to: workspace.rootTilingContainer, adaptiveWeight: 1, index: indexBindLast)
        }
        return ExitCode.success
    }
}
