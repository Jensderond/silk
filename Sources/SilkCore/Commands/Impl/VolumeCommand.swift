struct VolumeCommand: ParsableCommand {
    enum Action: Equatable {
        case up, down, muteToggle, muteOn, muteOff
        case set(Int)

        static let argsUnion = "(up|down|mute-toggle|mute-on|mute-off|set)"
    }

    static let kind = CommandKind.volume
    static let help = HelpText.volume
    static let parser = ArgParser<Self>(
        flags: ["--no-gui": .falseBool(\.gui)],
        positional: [.mandatory(\.action, placeholder: Action.argsUnion) { input in
            switch input.arg {
                case "up": return .success(.up, advanceBy: 1)
                case "down": return .success(.down, advanceBy: 1)
                case "mute-toggle": return .success(.muteToggle, advanceBy: 1)
                case "mute-off": return .success(.muteOff, advanceBy: 1)
                case "mute-on": return .success(.muteOn, advanceBy: 1)
                case "set":
                    guard let arg = input.arg(relative: 1) else { return .failure("set argument must be followed by <number>", advanceBy: 1) }
                    guard let value = Int(arg) else { return .failure("Can't parse number '\(arg)'", advanceBy: 2) }
                    guard (0 ... 100).contains(value) else { return .failure("\(value) must be in range from 0 to 100", advanceBy: 2) }
                    return .success(.set(value), advanceBy: 2)
                default:
                    return .failure("Unknown argument '\(input.arg)'. Possible values: \(Action.argsUnion)", advanceBy: 1)
            }
        }]
    )

    /// One step of the macOS volume keys.
    static let step: Float = 0.0625

    var common: CommonArgs
    var gui = true
    var action = Action.up
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        let platform = context.world.platform
        guard var state = platform.volume() else { return context.io.fail(internalErrorMessage("Can't read the output volume")) }
        switch action {
            case .up:
                state.level = min(1, state.level + Self.step)
                state.isMuted = false
            case .down:
                state.level = max(0, state.level - Self.step)
                state.isMuted = state.level == 0
            case .muteToggle:
                state.isMuted.toggle()
            case .muteOn:
                state.isMuted = true
            case .muteOff:
                state.isMuted = false
            case .set(let value):
                state.level = Float(value) / 100
                state.isMuted = value == 0
        }
        platform.setVolume(state, showHUD: gui)
        return ExitCode.success
    }
}
