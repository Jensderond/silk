/// Toggles macOS native fullscreen. Consecutive commands may misbehave because macOS reports the new state
/// with a delay (AeroSpace problem ID-B6E178F2); the same applies to `macos-native-minimize`.
struct MacosNativeFullscreenCommand: ParsableCommand {
    static let kind = CommandKind.macosNativeFullscreen
    static let help = HelpText.macosNativeFullscreen
    static let parser = ArgParser<Self>(
        flags: [
            "--fail-if-noop": .trueBool(\.failIfNoop),
            "--window-id": .windowId,
        ],
        positional: [.value(\.toggle, ToggleState.parse)]
    )

    var common: CommonArgs
    var toggle = ToggleState.toggle
    var failIfNoop = false
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    static func parse(_ args: [String]) -> ParsedCmd<MacosNativeFullscreenCommand> {
        parseArgs(args).filter("--fail-if-noop requires 'on' or 'off' argument") { $0.failIfNoop.implies($0.toggle == .on || $0.toggle == .off) }
    }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        guard let target = context.resolveTarget(common) else { return ExitCode.fail }
        guard let window = target.window else { return context.io.fail(noWindowIsFocused) }
        let previousState = window.isMacosFullscreen
        let newState = switch toggle {
            case .on: true
            case .off: false
            case .toggle: !previousState
        }
        if newState == previousState {
            if failIfNoop { return ExitCode.fail }
            return context.io.succeed(warning: (newState ? "Already fullscreen. " : "Already not fullscreen. ")
                + "Tip: use --fail-if-noop to exit with non-zero exit code")
        }
        world.platform.setNativeFullscreen(window: window.id, newState)
        guard let workspace = window.nodeWorkspace else { return context.io.fail(windowIsntPartOfTree(window)) }
        if newState {
            window.bind(to: workspace.macosFullscreenWindowsContainer, adaptiveWeight: 1, index: indexBindLast)
        } else if case .macos(let prevParentKind) = window.layoutReason {
            world.exitMacosNativeUnconventionalState(window, prevParentKind: prevParentKind, workspace: workspace)
        } else {
            world.relayoutWindow(window, on: workspace)
        }
        return ExitCode.success
    }
}

func windowIsntPartOfTree(_ window: Window) -> String {
    "Window \(window.id) is not part of tree (minimized or hidden)"
}
