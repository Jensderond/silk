struct ListMonitorsCommand: ParsableCommand {
    static let kind = CommandKind.listMonitors
    static let help = HelpText.listMonitors
    static let parser = ArgParser<Self>(
        flags: [
            "--focused": .optionalBool(\.focused),
            "--mouse": .optionalBool(\.mouse),
            "--format": .format(\.customFormat, for: .monitor),
            "--count": .trueBool(\.outputOnlyCount),
            "--json": .trueBool(\.json),
        ],
        positional: [],
        conflictingOptions: [["--count", "--format"], ["--count", "--json"]]
    )

    var common: CommonArgs
    var focused: Bool?
    var mouse: Bool?
    var customFormat: FormatTokens = []
    var outputOnlyCount = false
    var json = false
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    var format: FormatTokens {
        customFormat.isEmpty
            ? [.interVar(.formatVar(.monitor(.monitorId))), .interVar(.plain(.rightPadding)), .literal(" | "), .interVar(.formatVar(.monitor(.monitorName)))]
            : customFormat
    }

    static func parse(_ args: [String]) -> ParsedCmd<ListMonitorsCommand> {
        parseArgs(args).validatingJSONFormat(\.json, \.customFormat)
    }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        let focus = world.focus
        var monitors = world.sortedMonitors
        if let focused {
            monitors = monitors.filter { (world.activeWorkspace(on: $0) === focus.workspace) == focused }
        }
        if let mouse {
            let mouseWorkspace = world.activeWorkspace(on: world.monitorApproximation(world.platform.mouseLocation))
            monitors = monitors.filter { (world.activeWorkspace(on: $0) === mouseWorkspace) == mouse }
        }
        return printList(monitors.map(AeroObj.monitor), format: format, isDefaultFormat: customFormat.isEmpty, json: json, countOnly: outputOnlyCount, context)
    }
}
