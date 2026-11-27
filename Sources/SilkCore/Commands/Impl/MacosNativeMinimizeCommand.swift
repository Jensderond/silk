struct MacosNativeMinimizeCommand: ParsableCommand {
    static let kind = CommandKind.macosNativeMinimize
    static let help = HelpText.macosNativeMinimize
    static let parser = ArgParser<Self>(flags: ["--window-id": .windowId], positional: [])

    var common: CommonArgs
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        // Already minimized windows don't resolve: they don't belong to a workspace
        guard let target = context.resolveTarget(common) else { return ExitCode.fail }
        guard let window = target.window else { return context.io.fail(noWindowIsFocused) }
        guard !window.isMacosMinimized else {
            return context.io.fail("The command is uncapable of unminimizing windows yet. Sorry")
        }
        context.world.platform.setMinimized(window: window.id, true)
        // Recorded now, not when macOS reports it, so the window returns to where it was (floating stays floating)
        if window.layoutReason == .standard, let parent = window.parent, let parentKind = NonLeafNodeKind(parent) {
            window.layoutReason = .macos(prevParentKind: parentKind)
        }
        window.isMacosMinimized = true
        window.bind(to: context.world.minimizedContainer, adaptiveWeight: 1, index: indexBindLast)
        return ExitCode.success
    }
}
