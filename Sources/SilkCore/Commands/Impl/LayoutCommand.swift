import CoreGraphics
import SilkConfig

struct LayoutCommand: ParsableCommand {
    enum LayoutDescription: String, CaseIterable, Equatable {
        case accordion, tiles
        case horizontal, vertical
        case h_accordion, v_accordion, h_tiles, v_tiles
        case tiling, floating

        var isTilingOrFloating: Bool { self == .tiling || self == .floating }

        static func parse(_ raw: String) -> LayoutDescription? {
            if let parsed = LayoutDescription(rawValue: raw) { return parsed }
            return switch raw {
                case "list": .tiles
                case "h_list": .h_tiles
                case "v_list": .v_tiles
                default: nil
            }
        }
    }

    static let kind = CommandKind.layout
    static let help = HelpText.layout
    static let parser = ArgParser<Self>(
        flags: [
            "--window-id": .windowId,
            "--workspace": .workspace,
            "--root": .trueBool(\.root),
            "--fail-if-noop": .trueBool(\.failIfNoop),
            "--for-next-detected-window": .trueBool(\.forNextDetectedWindow),
        ],
        positional: [.mandatory(\.toggleBetween, placeholder: LayoutDescription.unionLiteral) { input in
            let args = input.nonFlagArgs
            var result: [LayoutDescription] = []
            for (index, arg) in args.enumerated() {
                guard let layout = LayoutDescription.parse(arg) else {
                    return .failure("Can't parse '\(arg)'\nPossible values: \(LayoutDescription.unionLiteral)", advanceBy: index + 1)
                }
                result.append(layout)
            }
            return .success(result, advanceBy: args.count)
        }],
        conflictingOptions: [
            ["--window-id", "--workspace"],
            ["--for-next-detected-window", "--window-id"],
            ["--for-next-detected-window", "--workspace"],
            ["--for-next-detected-window", "--root"],
            ["--for-next-detected-window", "--fail-if-noop"],
        ]
    )

    var common: CommonArgs
    var toggleBetween: [LayoutDescription] = []
    var root = false
    var failIfNoop = false
    var forNextDetectedWindow = false
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    init(toggleBetween: [LayoutDescription]) {
        self.init(rawArgs: [])
        self.toggleBetween = toggleBetween
    }

    static func parse(_ args: [String]) -> ParsedCmd<LayoutCommand> {
        parseArgs(args)
            .filter("layout command: --root and tiling|floating are incompatible") { command in
                !command.root || command.toggleBetween.allSatisfy { !$0.isTilingOrFloating }
            }
            .filter("layout command: --for-next-detected-window allows only one tiling|floating <target-layout> argument") { command in
                !command.forNextDetectedWindow || (command.toggleBetween.count == 1 && command.toggleBetween[0].isTilingOrFloating)
            }
            .filter("--workspace flag requires using an explicit --root flag") { ($0.common.workspaceName != nil).implies($0.root) }
            .filter("--fail-if-noop allows only one <target-layout> argument") { $0.failIfNoop.implies($0.toggleBetween.count == 1) }
    }

    /// The container whose layout the command changes.
    private enum Node {
        case tiling(TilingContainer)
        case floating(FloatingWindowsContainer)

        func matches(_ layout: LayoutDescription) -> Bool {
            let tiling: TilingContainer? = if case .tiling(let container) = self { container } else { nil }
            return switch layout {
                case .accordion: tiling?.layout == .accordion
                case .tiles: tiling?.layout == .tiles
                case .horizontal: tiling?.orientation == .h
                case .vertical: tiling?.orientation == .v
                case .h_accordion: tiling.map { $0.layout == .accordion && $0.orientation == .h } == true
                case .v_accordion: tiling.map { $0.layout == .accordion && $0.orientation == .v } == true
                case .h_tiles: tiling.map { $0.layout == .tiles && $0.orientation == .h } == true
                case .v_tiles: tiling.map { $0.layout == .tiles && $0.orientation == .v } == true
                case .tiling: tiling != nil
                case .floating: tiling == nil
            }
        }
    }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        let io = context.io
        if forNextDetectedWindow {
            guard toggleBetween.count == 1 else { return io.fail(internalErrorMessage()) }
            world.layoutForNextDetectedWindow = toggleBetween[0]
            return ExitCode.success
        }
        guard let target = context.resolveTarget(common) else { return ExitCode.fail }

        let node: Node
        if let window = root ? nil : target.window {
            switch window.parent {
                case let container as FloatingWindowsContainer:
                    node = .floating(container)
                case let container as TilingContainer:
                    node = .tiling(container)
                case is CollapsedWindowsContainer:
                    return io.fail("Can't change layout of a window minimized to a bar")
                case is MacosFullscreenWindowsContainer, is MacosHiddenAppsWindowsContainer, is MacosMinimizedWindowsContainer:
                    return io.fail("Can't change layout for macOS minimized, fullscreen windows or windows or hidden apps. This behavior is subject to change")
                default:
                    return io.fail(internalErrorMessage())
            }
        } else {
            node = .tiling(target.workspace.rootTilingContainer)
        }

        let targetDescription = toggleBetween.first { !node.matches($0) } ?? toggleBetween[0]
        if node.matches(targetDescription) {
            if failIfNoop { return ExitCode.fail }
            return io.succeed(warning: "Already in the requested \(targetDescription.rawValue) mode. Tip: use --fail-if-noop to exit with non-zero exit code")
        }
        switch targetDescription {
            case .h_accordion: return changeTilingLayout(io, world, .accordion, .h, node)
            case .v_accordion: return changeTilingLayout(io, world, .accordion, .v, node)
            case .h_tiles: return changeTilingLayout(io, world, .tiles, .h, node)
            case .v_tiles: return changeTilingLayout(io, world, .tiles, .v, node)
            case .accordion: return changeTilingLayout(io, world, .accordion, nil, node)
            case .tiles: return changeTilingLayout(io, world, .tiles, nil, node)
            case .horizontal: return changeTilingLayout(io, world, nil, .h, node)
            case .vertical: return changeTilingLayout(io, world, nil, .v, node)
            case .tiling:
                guard let window = target.window else { return io.fail(noWindowIsFocused) }
                switch node {
                    case .tiling:
                        return ExitCode.success
                    case .floating(let container):
                        window.lastFloatingSize = window.lastKnownFrame?.size ?? window.lastFloatingSize
                        window.hasFloatedByCommand = true
                        guard let workspace = container.nodeWorkspace else { return io.fail(internalErrorMessage()) }
                        world.relayoutWindow(window, on: workspace, forceTile: true)
                        return ExitCode.success
                }
            case .floating:
                guard let window = target.window else { return io.fail(noWindowIsFocused) }
                world.bindAsFloatingWindow(window, to: target.workspace)
                if var size = window.lastFloatingSize, let frame = window.lastKnownFrame {
                    // A window that was as large as a tile or the screen wouldn't look floating at all. Only the
                    // first time: after that the size is the one the window had when it last floated.
                    // A remembered size that fills the screen is never worth keeping.
                    let screen = world.monitor(of: target.workspace).visibleFrame.size
                    let fillsScreen = size.width >= screen.width * Self.fillsScreenFraction
                        || size.height >= screen.height * Self.fillsScreenFraction
                    if !window.hasFloatedByCommand || fillsScreen {
                        size.width = min(size.width, Self.maxToggledFloatingSize.width)
                        size.height = min(size.height, Self.maxToggledFloatingSize.height)
                        window.lastFloatingSize = size
                        window.hasFloatedByCommand = true
                    }
                    var origin = frame.origin
                    if !window.isHiddenInCorner {
                        // Resize around the tile's centre, so the window lifts out of its tile instead of
                        // collapsing into the tile's corner while its neighbours grow underneath
                        let visible = world.monitor(of: target.workspace).visibleFrame
                        origin = CGPoint(
                            x: (frame.midX - size.width / 2).coerced(in: visible.minX ... max(visible.minX, visible.maxX - size.width)),
                            y: (frame.midY - size.height / 2).coerced(in: visible.minY ... max(visible.minY, visible.maxY - size.height))
                        )
                    }
                    window.lastKnownFrame = CGRect(origin: origin, size: size)
                }
                return ExitCode.success
        }
    }

    /// A window made floating with this command for the first time is at most this large (Silk-only; AeroSpace
    /// keeps any size). The user can enlarge it afterwards.
    static let maxToggledFloatingSize = CGSize(width: 900, height: 800)
    /// A floating size covering at least this share of the monitor's width or height counts as filling the screen.
    static let fillsScreenFraction: CGFloat = 0.9

    private func changeTilingLayout(
        _ io: CommandIO,
        _ world: World,
        _ targetLayout: ContainerLayout?,
        _ targetOrientation: Orientation?,
        _ node: Node
    ) -> Int32 {
        switch node {
            case .floating:
                return io.fail("The window is non-tiling")
            case .tiling(let container):
                container.layout = targetLayout ?? container.layout
                container.changeOrientation(
                    targetOrientation ?? container.orientation,
                    normalizeOppositeOrientation: world.config.enableNormalizationOppositeOrientationForNestedContainers
                )
                return ExitCode.success
        }
    }
}
