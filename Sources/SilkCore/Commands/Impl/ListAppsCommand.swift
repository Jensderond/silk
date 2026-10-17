struct ListAppsCommand: ParsableCommand {
    static let kind = CommandKind.listApps
    static let help = HelpText.listApps
    static let parser = ArgParser<Self>(
        flags: [
            "--macos-native-hidden": .optionalBool(\.macosHidden),
            "--format": .format(\.customFormat, for: .app),
            "--count": .trueBool(\.outputOnlyCount),
            "--json": .trueBool(\.json),
        ],
        positional: [],
        conflictingOptions: [["--count", "--format"], ["--count", "--json"]]
    )

    var common: CommonArgs
    var macosHidden: Bool?
    var customFormat: FormatTokens = []
    var outputOnlyCount = false
    var json = false
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    var format: FormatTokens {
        customFormat.isEmpty
            ? [
                .interVar(.formatVar(.app(.appPid))), .interVar(.plain(.rightPadding)), .literal(" | "),
                .interVar(.formatVar(.app(.appBundleId))), .interVar(.plain(.rightPadding)), .literal(" | "),
                .interVar(.formatVar(.app(.appName))),
            ]
            : customFormat
    }

    static func parse(_ args: [String]) -> ParsedCmd<ListAppsCommand> {
        parseArgs(args).validatingJSONFormat(\.json, \.customFormat)
    }

    func run(_ context: CommandContext) -> Int32 {
        var apps = context.world.platform.runningApps()
        if let macosHidden { apps = apps.filter { $0.isHidden == macosHidden } }
        return printList(apps.map(AeroObj.app), format: format, isDefaultFormat: customFormat.isEmpty, json: json, countOnly: outputOnlyCount, context)
    }
}
