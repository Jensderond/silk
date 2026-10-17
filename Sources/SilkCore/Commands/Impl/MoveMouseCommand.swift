import CoreGraphics

struct MoveMouseCommand: ParsableCommand {
    enum MouseTarget: String, CaseIterable {
        case monitorLazyCenter = "monitor-lazy-center"
        case monitorForceCenter = "monitor-force-center"
        case windowLazyCenter = "window-lazy-center"
        case windowForceCenter = "window-force-center"
    }

    static let kind = CommandKind.moveMouse
    static let help = HelpText.moveMouse
    static let parser = ArgParser<Self>(
        flags: ["--fail-if-noop": .trueBool(\.failIfNoop)],
        positional: [.mandatory(\.mouseTarget, placeholder: "<mouse-position>", parseEnumArg(MouseTarget.self))]
    )

    var common: CommonArgs
    var failIfNoop = false
    var mouseTarget = MouseTarget.monitorLazyCenter
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    static func parse(_ args: [String]) -> ParsedCmd<MoveMouseCommand> {
        parseArgs(args).filter("--fail-if-noop is only compatible with window-lazy-center or monitor-lazy-center") {
            $0.failIfNoop.implies($0.mouseTarget == .windowLazyCenter || $0.mouseTarget == .monitorLazyCenter)
        }
    }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        let io = context.io
        let mouse = world.platform.mouseLocation
        guard let target = context.resolveTarget(common) else { return ExitCode.fail }
        switch mouseTarget {
            case .windowLazyCenter:
                guard let rect = windowRect(target, io) else { return ExitCode.fail }
                if rect.containsPoint(mouse) {
                    if failIfNoop { return ExitCode.fail }
                    return io.succeed(warning: "The mouse already belongs to the window. Tip: use --fail-if-noop to exit with non-zero code")
                }
                return moveMouse(rect.center, world)
            case .windowForceCenter:
                guard let rect = windowRect(target, io) else { return ExitCode.fail }
                return moveMouse(rect.center, world)
            case .monitorLazyCenter:
                let rect = world.monitor(of: target.workspace).frame
                if rect.containsPoint(mouse) {
                    if failIfNoop { return ExitCode.fail }
                    return io.succeed(warning: "The mouse already belongs to the monitor. Tip: use --fail-if-noop to exit with non-zero code")
                }
                return moveMouse(rect.center, world)
            case .monitorForceCenter:
                return moveMouse(world.monitor(of: target.workspace).frame.center, world)
        }
    }

    private func moveMouse(_ point: CGPoint, _ world: World) -> Int32 {
        world.platform.moveMouse(to: point)
        return ExitCode.success
    }

    private func windowRect(_ target: LiveFocus, _ io: CommandIO) -> CGRect? {
        guard let window = target.window else {
            io.err(noWindowIsFocused)
            return nil
        }
        guard let rect = window.lastAppliedLayoutPhysicalRect ?? window.lastKnownFrame else {
            io.err("Failed to get rect of window '\(window.id)'")
            return nil
        }
        return rect
    }
}
