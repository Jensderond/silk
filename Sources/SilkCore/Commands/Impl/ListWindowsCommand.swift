struct ListWindowsCommand: ParsableCommand {
    enum WorkspaceFilter: Equatable {
        case focused, visible
        case name(WorkspaceName)
    }

    struct FilteringOptions: Equatable {
        var monitors: [MonitorIdFilter] = []
        var focused = false
        var workspaces: [WorkspaceFilter] = []
        var pidFilter: Int32?
        var appIdFilter: String?
    }

    static let kind = CommandKind.listWindows
    static let help = HelpText.listWindows
    static let parser = ArgParser<Self>(
        flags: [
            "--all": .trueBool(\.allAlias),
            "--focused": .trueBool(\.filteringOptions.focused),
            "--monitor": .value(\.filteringOptions.monitors, MonitorIdFilter.parseList),
            "--workspace": .value(\.filteringOptions.workspaces, parseWorkspaceFilters),
            "--pid": .single(\.filteringOptions.pidFilter, "<pid>") { raw in
                Int32(raw).map { .success($0) } ?? .failure(ParseError("Can't convert to Int32"))
            },
            "--app-bundle-id": .single(\.filteringOptions.appIdFilter, "<app-bundle-id>") { .success($0) },
            "--format": .format(\.customFormat, for: .window),
            "--count": .trueBool(\.outputOnlyCount),
            "--json": .trueBool(\.json),
        ],
        positional: [],
        conflictingOptions: [
            ["--all", "--focused", "--workspace"],
            ["--all", "--focused", "--monitor"],
            ["--count", "--format"],
            ["--count", "--json"],
        ]
    )

    var common: CommonArgs
    var allAlias = false
    var filteringOptions = FilteringOptions()
    var customFormat: FormatTokens = []
    var outputOnlyCount = false
    var json = false
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    var format: FormatTokens {
        customFormat.isEmpty
            ? [
                .interVar(.formatVar(.window(.windowId))), .interVar(.plain(.rightPadding)), .literal(" | "),
                .interVar(.formatVar(.app(.appName))), .interVar(.plain(.rightPadding)), .literal(" | "),
                .interVar(.formatVar(.window(.windowTitle))),
            ]
            : customFormat
    }

    static func parse(_ args: [String]) -> ParsedCmd<ListWindowsCommand> {
        let args = args.map { $0 == "--app-id" ? "--app-bundle-id" : $0 } // Compatibility
        return parser.parse(ListWindowsCommand(rawArgs: args), args, help: help)
            .filter("Mandatory option is not specified (--focused|--all|--monitor|--workspace)") { raw in
                raw.filteringOptions.focused || raw.allAlias || !raw.filteringOptions.monitors.isEmpty || !raw.filteringOptions.workspaces.isEmpty
            }
            .filter("--all conflicts with \"filtering\" flags. Please use '--monitor all' instead of '--all' alias") { raw in
                raw.allAlias.implies(raw.filteringOptions == FilteringOptions())
            }
            .filter("--focused conflicts with other \"filtering\" flags") { raw in
                var others = raw.filteringOptions
                others.focused = false
                return raw.filteringOptions.focused.implies(others == FilteringOptions())
            }
            .map { raw in
                guard raw.allAlias else { return raw }
                var normalized = raw
                normalized.filteringOptions.monitors = [.all]
                normalized.allAlias = false
                return normalized
            }
            .validatingJSONFormat(\.json, \.customFormat)
    }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        let focus = world.focus
        var windows: [Window]
        if filteringOptions.focused {
            guard let window = focus.window else { return context.io.fail(noWindowIsFocused) }
            windows = [window]
        } else {
            var workspaces: [Workspace]
            if filteringOptions.workspaces.isEmpty {
                workspaces = world.allWorkspaces
            } else {
                var seen: Set<ObjectIdentifier> = []
                workspaces = filteringOptions.workspaces.flatMap { filter -> [Workspace] in
                    switch filter {
                        case .focused: [focus.workspace]
                        case .visible: world.allWorkspaces.filter(world.isVisible)
                        case .name(let name): [world.workspace(named: name.raw)]
                    }
                }
                .filter { seen.insert(ObjectIdentifier($0)).inserted }
            }
            if !filteringOptions.monitors.isEmpty {
                let monitors = filteringOptions.monitors.resolveMonitors(context)
                if monitors.isEmpty { return ExitCode.fail }
                workspaces = workspaces.filter { monitors.contains(world.monitor(of: $0).id) }
            }
            windows = workspaces.flatMap(\.allLeafWindowsRecursive)
            if let pid = filteringOptions.pidFilter { windows = windows.filter { $0.pid == pid } }
            if let appId = filteringOptions.appIdFilter { windows = windows.filter { $0.bundleId == appId } }
        }
        if outputOnlyCount {
            context.io.out(String(windows.count))
            return ExitCode.success
        }
        let needsTitle = format.needsWindowTitle
        let objects = windows
            .map { (window: $0, title: needsTitle ? $0.title : nil) }
            .sorted { a, b in ((a.window.appName ?? ""), (a.title ?? "")) < ((b.window.appName ?? ""), (b.title ?? "")) }
            .map { AeroObj.window($0.window, title: $0.title) }
        return printList(objects, format: format, isDefaultFormat: customFormat.isEmpty, json: json, countOnly: false, context)
    }
}

private func parseWorkspaceFilters(_ input: FlagInput) -> ParsedArg<[ListWindowsCommand.WorkspaceFilter]> {
    let args = input.nonFlagArgs
    let possibleValues = "<workspace> possible values: (<workspace-name>|focused|visible)"
    if args.isEmpty { return .failure("<workspace>... is mandatory. \(possibleValues)", advanceBy: 0) }
    var result: [ListWindowsCommand.WorkspaceFilter] = []
    for (index, raw) in args.enumerated() {
        switch raw {
            case "visible": result.append(.visible)
            case "focused": result.append(.focused)
            default:
                switch WorkspaceName.parse(raw) {
                    case .success(let name): result.append(.name(name))
                    case .failure(let error): return .failure(error.message, advanceBy: index + 1)
                }
        }
    }
    return .success(result, advanceBy: result.count)
}
