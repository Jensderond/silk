import Foundation

struct ListModesCommand: ParsableCommand {
    static let kind = CommandKind.listModes
    static let help = HelpText.listModes
    static let parser = ArgParser<Self>(
        flags: [
            "--count": .trueBool(\.outputOnlyCount),
            "--current": .trueBool(\.current),
            "--json": .trueBool(\.json),
        ],
        positional: [],
        conflictingOptions: [["--count", "--current"], ["--count", "--json"]]
    )

    var common: CommonArgs
    var current = false
    var json = false
    var outputOnlyCount = false
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        let modes = current ? [world.activeMode ?? mainModeId] : world.config.modes.keys.sorted()
        if outputOnlyCount {
            context.io.out(String(modes.count))
        } else if json {
            guard let encoded = JSONEncoder.aeroSpace.encodeToString(modes.map { ["mode-id": $0] }) else {
                return context.io.fail("Failed to encode JSON")
            }
            context.io.out(encoded)
        } else {
            context.io.out(modes)
        }
        return ExitCode.success
    }
}
