struct RunCallbackCommand: ParsableCommand {
    enum Callback: String, CaseIterable {
        case onWindowDetected = "on-window-detected"
        case onFocusChanged = "on-focus-changed"
        case onFocusedMonitorChanged = "on-focused-monitor-changed"
    }

    static let kind = CommandKind.runCallback
    static let help = HelpText.runCallback
    static let parser = ArgParser<Self>(
        flags: [
            "--for-every-window": .trueBool(\.forEveryWindow),
            "--window-id": .windowId,
        ],
        positional: [.mandatory(\.callback, placeholder: "<callback>", parseEnumArg(Callback.self))],
        conflictingOptions: [["--for-every-window", "--window-id"]]
    )

    var common: CommonArgs
    var forEveryWindow = false
    var callback = Callback.onWindowDetected
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    static func parse(_ args: [String]) -> ParsedCmd<RunCallbackCommand> {
        parseArgs(args)
            .filter("--for-every-window is only allowed with 'on-window-detected'") { $0.forEveryWindow.implies($0.callback == .onWindowDetected) }
            .filter("--window-id is only allowed with 'on-window-detected'") { ($0.common.windowId != nil).implies($0.callback == .onWindowDetected) }
    }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        guard let target = context.resolveTarget(common) else { return ExitCode.fail }
        switch callback {
            case .onWindowDetected where forEveryWindow:
                // AeroSpace quirk kept for exit-code parity: 2 when there are no windows.
                var exitCode = ExitCode.fail
                for window in world.allWindows {
                    exitCode = world.onWindowDetected(window, env: context.env, io: context.io)
                }
                return exitCode
            case .onWindowDetected:
                guard let window = target.window else { return context.io.fail(noWindowIsFocused) }
                return world.onWindowDetected(window, env: context.env, io: context.io)
            case .onFocusChanged:
                return world.onFocusChanged(target, env: context.env, io: context.io)
            case .onFocusedMonitorChanged:
                return world.onFocusedMonitorChanged(target, env: context.env, io: context.io)
        }
    }
}
