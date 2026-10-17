struct FullscreenCommand: ParsableCommand {
    static let kind = CommandKind.fullscreen
    static let help = HelpText.fullscreen
    static let parser = ArgParser<Self>(
        flags: [
            "--no-outer-gaps": .trueBool(\.noOuterGaps),
            "--fail-if-noop": .trueBool(\.failIfNoop),
            "--window-id": .windowId,
        ],
        positional: [.value(\.toggle, ToggleState.parse)]
    )

    var common: CommonArgs
    var toggle = ToggleState.toggle
    var noOuterGaps = false
    var failIfNoop = false
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    static func parse(_ args: [String]) -> ParsedCmd<FullscreenCommand> {
        parseArgs(args)
            .filterNot("--no-outer-gaps is incompatible with 'off' argument") { $0.toggle == .off && $0.noOuterGaps }
            .filter("--fail-if-noop requires 'on' or 'off' argument") { $0.failIfNoop.implies($0.toggle == .on || $0.toggle == .off) }
    }

    func run(_ context: CommandContext) -> Int32 {
        guard let target = context.resolveTarget(common) else { return ExitCode.fail }
        guard let window = target.window else { return context.io.fail(noWindowIsFocused) }
        let newState = switch toggle {
            case .on: true
            case .off: false
            case .toggle: !window.isFullscreen
        }
        if newState == window.isFullscreen {
            if failIfNoop { return ExitCode.fail }
            return context.io.succeed(warning: newState
                ? "Already fullscreen. Tip: use --fail-if-noop to exit with non-zero code"
                : "Already not fullscreen. Tip: use --fail-if-noop to exit with non-zero code")
        }
        window.isFullscreen = newState
        window.noOuterGapsInFullscreen = noOuterGaps
        // Fullscreen applies to the most recent window of the workspace
        window.markAsMostRecentChild()
        return ExitCode.success
    }
}
