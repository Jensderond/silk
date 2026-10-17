struct ListWorkspacesCommand: ParsableCommand {
    struct FilteringOptions: Equatable {
        var onMonitors: [MonitorIdFilter] = []
        var visible: Bool?
        var empty: Bool?
    }

    static let kind = CommandKind.listWorkspaces
    static let help = HelpText.listWorkspaces
    static let parser = ArgParser<Self>(
        flags: [
            "--focused": .trueBool(\.focusedAlias),
            "--all": .trueBool(\.allAlias),
            "--visible": .optionalBool(\.filteringOptions.visible),
            "--empty": .optionalBool(\.filteringOptions.empty),
            "--monitor": .value(\.filteringOptions.onMonitors, MonitorIdFilter.parseList),
            "--format": .format(\.customFormat, for: .workspace),
            "--count": .trueBool(\.outputOnlyCount),
            "--json": .trueBool(\.json),
        ],
        positional: [],
        conflictingOptions: [["--all", "--focused", "--monitor"], ["--count", "--format"], ["--count", "--json"]]
    )

    var common: CommonArgs
    var allAlias = false
    var focusedAlias = false
    var filteringOptions = FilteringOptions()
    var customFormat: FormatTokens = [.interVar(.formatVar(.workspace(.workspaceName)))]
    var outputOnlyCount = false
    var json = false
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    var format: FormatTokens { customFormat.isEmpty ? [.interVar(.formatVar(.workspace(.workspaceName)))] : customFormat }

    static func parse(_ args: [String]) -> ParsedCmd<ListWorkspacesCommand> {
        parseArgs(args)
            .filter("Mandatory option is not specified (--all|--focused|--monitor)") { raw in
                raw.allAlias || raw.focusedAlias || !raw.filteringOptions.onMonitors.isEmpty
            }
            .filter("--all conflicts with any other \"filtering\" options") { raw in
                raw.allAlias.implies(raw.filteringOptions == FilteringOptions())
            }
            .filter("--focused conflicts with all other \"filtering\" options") { raw in
                raw.focusedAlias.implies(raw.filteringOptions == FilteringOptions())
            }
            .map { raw in
                var normalized = raw
                if raw.allAlias {
                    normalized.filteringOptions.onMonitors = [.all]
                    normalized.allAlias = false
                }
                if raw.focusedAlias {
                    normalized.filteringOptions.onMonitors = [.focused]
                    normalized.filteringOptions.visible = true
                    normalized.focusedAlias = false
                }
                return normalized
            }
            .validatingJSONFormat(\.json, \.customFormat)
    }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        var workspaces = world.allWorkspaces
        if let visible = filteringOptions.visible {
            workspaces = workspaces.filter { world.isVisible($0) == visible }
        }
        if !filteringOptions.onMonitors.isEmpty {
            let monitors = filteringOptions.onMonitors.resolveMonitors(context)
            if monitors.isEmpty { return ExitCode.fail }
            workspaces = workspaces.filter { monitors.contains(world.monitor(of: $0).id) }
        }
        if let empty = filteringOptions.empty {
            workspaces = workspaces.filter { $0.isEffectivelyEmpty == empty }
        }
        // AeroSpace's default --format is non-empty, so %{right-padding} is never dropped in --json
        return printList(workspaces.map(AeroObj.workspace), format: format, isDefaultFormat: customFormat.isEmpty, json: json, countOnly: outputOnlyCount, context)
    }
}
