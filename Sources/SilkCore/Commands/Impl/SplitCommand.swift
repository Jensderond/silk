struct SplitCommand: ParsableCommand {
    enum SplitArg: String, CaseIterable {
        case horizontal, vertical, opposite
    }

    static let kind = CommandKind.split
    static let help = HelpText.split
    static let parser = ArgParser<Self>(
        flags: ["--window-id": .windowId],
        positional: [.mandatory(\.arg, placeholder: SplitArg.unionLiteral, parseEnumArg(SplitArg.self))]
    )

    var common: CommonArgs
    var arg = SplitArg.opposite
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        let io = context.io
        if world.config.enableNormalizationFlattenContainers {
            return io.fail("'split' has no effect when 'enable-normalization-flatten-containers' normalization enabled. My recommendation: keep the normalizations enabled, and prefer 'join-with' over 'split'.")
        }
        guard let target = context.resolveTarget(common) else { return ExitCode.fail }
        guard let window = target.window else { return io.fail(noWindowIsFocused) }
        switch window.parent {
            case is FloatingWindowsContainer:
                return io.fail("Can't split floating windows")
            case let parent as TilingContainer:
                let orientation: Orientation = switch arg {
                    case .vertical: .v
                    case .horizontal: .h
                    case .opposite: parent.orientation.opposite
                }
                if parent.children.count == 1 {
                    parent.changeOrientation(orientation, normalizeOppositeOrientation: world.config.enableNormalizationOppositeOrientationForNestedContainers)
                } else {
                    let data = window.unbindFromParent()
                    let newParent = TilingContainer(parent: parent, adaptiveWeight: data.adaptiveWeight, orientation, .tiles, index: data.index)
                    window.bind(to: newParent, adaptiveWeight: weightAuto, index: 0)
                }
                return ExitCode.success
            case is MacosMinimizedWindowsContainer, is MacosFullscreenWindowsContainer, is MacosHiddenAppsWindowsContainer:
                return io.fail("Can't split macos fullscreen, minimized windows and windows of hidden apps. This behavior may change in the future")
            default:
                return io.fail(internalErrorMessage())
        }
    }
}
