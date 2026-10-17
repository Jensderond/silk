struct JoinWithCommand: ParsableCommand {
    static let kind = CommandKind.joinWith
    static let help = HelpText.joinWith
    static let parser = ArgParser<Self>(
        flags: ["--window-id": .windowId],
        positional: [.mandatory(\.direction, placeholder: CardinalDirection.unionLiteral, parseEnumArg(CardinalDirection.self))]
    )

    var common: CommonArgs
    var direction = CardinalDirection.left
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        guard let target = context.resolveTarget(common) else { return ExitCode.fail }
        guard let currentWindow = target.window else { return context.io.fail(noWindowIsFocused) }
        guard let (parent, ownIndex) = currentWindow.closestParent(hasChildrenInDirection: direction, withLayout: nil) else {
            return context.io.fail("No windows in the specified direction")
        }
        let joinWithTarget = parent.children[ownIndex + direction.focusOffset]
        let previousBinding = joinWithTarget.unbindFromParent()
        let newParent = TilingContainer(
            parent: parent,
            adaptiveWeight: previousBinding.adaptiveWeight,
            parent.orientation.opposite,
            .tiles,
            index: previousBinding.index
        )
        currentWindow.unbindFromParent()
        joinWithTarget.bind(to: newParent, adaptiveWeight: weightAuto, index: 0)
        currentWindow.bind(to: newParent, adaptiveWeight: weightAuto, index: direction.isPositive ? 0 : indexBindLast)
        return ExitCode.success
    }
}
