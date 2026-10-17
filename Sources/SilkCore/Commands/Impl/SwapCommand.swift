struct SwapCommand: ParsableCommand {
    static let kind = CommandKind.swap
    static let help = HelpText.swap
    static let parser = ArgParser<Self>(
        flags: [
            "--swap-focus": .trueBool(\.swapFocus),
            "--wrap-around": .trueBool(\.wrapAround),
            "--window-id": .windowId,
        ],
        positional: [.mandatory(\.target, placeholder: CardinalOrDfsDirection.unionLiteral, parseEnumArg(CardinalOrDfsDirection.self))]
    )

    var common: CommonArgs
    var target = CardinalOrDfsDirection.direction(.left)
    var swapFocus = false
    var wrapAround = false
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        guard let focus = context.resolveTarget(common) else { return ExitCode.fail }
        guard let currentWindow = focus.window else { return context.io.fail(noWindowIsFocused) }
        let targetWindow: Window?
        switch target {
            case .direction(let direction):
                if let (parent, ownIndex) = currentWindow.closestParent(hasChildrenInDirection: direction, withLayout: nil) {
                    targetWindow = parent.children[ownIndex + direction.focusOffset].findLeafWindowRecursive(snappedTo: direction.opposite)
                } else if wrapAround {
                    targetWindow = focus.workspace.findLeafWindowRecursive(snappedTo: direction.opposite)
                } else {
                    return ExitCode.fail
                }
            case .dfsRelative(let nextPrev):
                let windows = focus.workspace.rootTilingContainer.allLeafWindowsRecursive
                guard let currentIndex = windows.firstIndex(where: { $0 === focus.window }) else { return ExitCode.fail }
                var targetIndex = nextPrev == .dfsNext ? currentIndex + 1 : currentIndex - 1
                if !windows.indices.contains(targetIndex) {
                    if !wrapAround { return ExitCode.fail }
                    targetIndex = (targetIndex + windows.count) % windows.count
                }
                targetWindow = windows[targetIndex]
        }
        guard let targetWindow else { return ExitCode.fail }
        swapWindows(mruDominant: currentWindow, targetWindow)
        if swapFocus { return ExitCode.from(context.world.focusWindow(targetWindow)) }
        return ExitCode.success
    }
}

/// Exchanges two windows' tree positions; `window1` is bound last so it stays the most recent.
func swapWindows(mruDominant window1: Window, _ window2: Window) {
    if window1 === window2 { return }
    let binding2 = window2.unbindFromParent()
    let binding1 = window1.unbindFromParent()
    window2.bind(to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
    window1.bind(to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
}
