/// Prints `list-*` results as text table, `--json` or `--count`.
func printList(
    _ objects: [AeroObj],
    format: FormatTokens,
    isDefaultFormat: Bool,
    json: Bool,
    countOnly: Bool,
    _ context: CommandContext
) -> Int32 {
    let io = context.io
    if countOnly {
        io.out(String(objects.count))
        return ExitCode.success
    }
    let formatter = Formatter(world: context.world)
    if json {
        switch formatter.formatJSON(objects, format, ignoreRightPadding: isDefaultFormat) {
            case .success(let json): io.out(json)
            case .failure(let error): return io.fail(error.message)
        }
        return ExitCode.success
    }
    switch formatter.format(objects, format) {
        case .success(let lines):
            io.out(lines)
            return ExitCode.success
        case .failure(let failure):
            return io.fail(failure.errors.map(\.description).joinErrors())
    }
}

extension ParsedCmd {
    /// Rejects `--format` values that `--json` can't represent.
    func validatingJSONFormat(_ json: (T) -> Bool, _ format: (T) -> FormatTokens) -> ParsedCmd<T> {
        flatMap { command in
            if json(command), let error = format(command).jsonIncompatibilityError { return .failure(error) }
            return .cmd(command)
        }
    }
}

extension [MonitorIdFilter] {
    /// Resolves `--monitor` values; reports and returns [] for an invalid id.
    func resolveMonitors(_ context: CommandContext) -> Set<MonitorID> {
        let world = context.world
        let sorted = world.sortedMonitors
        var result: Set<MonitorID> = []
        for filter in self {
            let resolved: [Monitor]
            switch filter {
                case .focused: resolved = [world.monitor(of: world.focus.workspace)]
                case .mouse: resolved = [world.monitorApproximation(world.platform.mouseLocation)]
                case .all: resolved = world.monitors
                case .index(let index):
                    guard let monitor = sorted.element(at: index) else {
                        context.io.err("Invalid monitor ID: \(index + 1)")
                        return []
                    }
                    resolved = [monitor]
            }
            result.formUnion(resolved.map(\.id))
        }
        return result
    }
}
