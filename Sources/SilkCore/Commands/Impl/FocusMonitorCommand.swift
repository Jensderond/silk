struct FocusMonitorCommand: ParsableCommand {
    static let kind = CommandKind.focusMonitor
    static let help = HelpText.focusMonitor
    static let parser = ArgParser<Self>(
        flags: ["--wrap-around": .trueBool(\.wrapAround)],
        positional: [
            .dashDash(mandatory: false),
            .mandatory(\.target, placeholder: MonitorTarget.cases.joinedCliArgs, MonitorTarget.parse),
        ]
    )

    var common: CommonArgs
    var wrapAround = false
    var target = MonitorTarget.relative(.next)
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    static func parse(_ args: [String]) -> ParsedCmd<FocusMonitorCommand> {
        parseArgs(args).filter("--wrap-around is incompatible with <monitor-pattern> argument") { !$0.wrapAround || !$0.target.isPatterns }
    }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        guard let focus = context.resolveTarget(common) else { return ExitCode.fail }
        switch world.resolve(target, from: world.monitor(of: focus.workspace), wrapAround: wrapAround) {
            case .success(let monitor): return ExitCode.from(world.focusWorkspace(world.activeWorkspace(on: monitor)))
            case .failure(let error): return context.io.fail(error.message)
        }
    }
}

extension World {
    /// Resolves a monitor target relative to `current`.
    func resolve(_ target: MonitorTarget, from current: Monitor, wrapAround: Bool) -> Result<Monitor, ParseError> {
        switch target {
            case .direction(let direction):
                guard let (monitorsInDirection, index) = findRelativeMonitor(from: current, inDirection: direction) else {
                    return .failure(ParseError("Should never happen. Can't find the current monitor"))
                }
                let monitor = wrapAround ? monitorsInDirection.element(wrappingIndex: index) : monitorsInDirection.element(at: index)
                guard let monitor else { return .failure(ParseError("No monitors in direction \(direction)")) }
                return .success(monitor)
            case .relative(let nextPrev):
                let monitors = sortedMonitors
                guard let currentIndex = monitors.firstIndex(where: { $0.id == current.id }) else {
                    return .failure(ParseError("Can't find current monitor"))
                }
                let index = nextPrev == .next ? currentIndex + 1 : currentIndex - 1
                let monitor = wrapAround ? monitors.element(wrappingIndex: index) : monitors.element(at: index)
                guard let monitor else { return .failure(ParseError("Can't find target monitor")) }
                return .success(monitor)
            case .patterns(let patterns):
                let monitors = sortedMonitors
                guard let monitor = patterns.lazy.compactMap({ self.resolve($0, sortedMonitors: monitors) }).first else {
                    return .failure(ParseError("None of the monitors match the pattern(s)"))
                }
                return .success(monitor)
        }
    }

    /// Monitors on the same row (left/right) or column (up/down) as `current`, and the index of the neighbour
    /// in `direction` (possibly out of bounds).
    func findRelativeMonitor(from current: Monitor, inDirection direction: CardinalDirection) -> ([Monitor], Int)? {
        let monitors = sortedMonitors.filter { $0.id == current.id || relation($0, to: current) == direction.orientation }
        guard let index = monitors.firstIndex(where: { $0.id == current.id }) else { return nil }
        return (monitors, index + direction.focusOffset)
    }

    /// `.h` if the monitors' vertical ranges overlap (side by side), `.v` otherwise.
    private func relation(_ monitor: Monitor, to other: Monitor) -> Orientation {
        let mine = monitor.frame
        let theirs = other.frame
        guard theirs.minY < theirs.maxY, mine.minY < mine.maxY else { return .h }
        return mine.minY < theirs.maxY && theirs.minY < mine.maxY ? .h : .v
    }
}
