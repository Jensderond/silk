struct CloseCommand: ParsableCommand {
    static let kind = CommandKind.close
    static let help = HelpText.close
    static let parser = ArgParser<Self>(
        flags: [
            "--quit-if-last-window": .trueBool(\.quitIfLastWindow),
            "--window-id": .windowId,
        ],
        positional: []
    )

    var common: CommonArgs
    var quitIfLastWindow = false
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        guard let target = context.resolveTarget(common) else { return ExitCode.fail }
        guard let window = target.window else { return context.io.fail("Empty workspace") }
        if quitIfLastWindow && world.windowsById.values.filter({ $0.pid == window.pid }).count == 1 {
            guard world.platform.terminateApp(pid: window.pid) else {
                return context.io.fail("Failed to quit '\(window.appName ?? "Unknown app")'")
            }
            for appWindow in world.allWindows where appWindow.pid == window.pid {
                world.garbageCollect(appWindow)
            }
            return ExitCode.success
        }
        world.garbageCollect(window)
        world.platform.close(window: window.id)
        return ExitCode.success
    }
}
