struct MoveCommand: ParsableCommand {
    enum Boundaries: String, CaseIterable {
        case workspace
        case allMonitorsOuterFrame = "all-monitors-outer-frame"
    }

    enum WhenBoundariesCrossed: String, CaseIterable {
        case stop
        case fail
        case createImplicitContainer = "create-implicit-container"
    }

    static let kind = CommandKind.move
    static let help = HelpText.move
    static let parser = ArgParser<Self>(
        flags: [
            "--window-id": .windowId,
            "--boundaries": .value(\.rawBoundaries, parseEnumFlag(Boundaries.self, missing: "<boundary>")),
            "--boundaries-action": .value(\.rawBoundariesAction, parseEnumFlag(WhenBoundariesCrossed.self, missing: "<action>")),
            "--fail-if-fullscreen": .trueBool(\.failIfFullscreen),
            "--fail-if-macos-native-fullscreen": .trueBool(\.failIfMacosNativeFullscreen),
        ],
        positional: [.mandatory(\.direction, placeholder: CardinalDirection.unionLiteral, parseEnumArg(CardinalDirection.self))]
    )

    var common: CommonArgs
    var direction = CardinalDirection.left
    var rawBoundaries: Boundaries?
    var rawBoundariesAction: WhenBoundariesCrossed?
    var failIfFullscreen = false
    var failIfMacosNativeFullscreen = false
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    var boundaries: Boundaries { rawBoundaries ?? .workspace }
    var boundariesAction: WhenBoundariesCrossed { rawBoundariesAction ?? .createImplicitContainer }

    private static let unconventionalWindowMessage =
        "moving macOS fullscreen, minimized windows and windows of hidden apps isn't yet supported. This behavior is subject to change"

    func run(_ context: CommandContext) -> Int32 {
        let io = context.io
        guard let target = context.resolveTarget(common) else { return ExitCode.fail }
        guard let window = target.window else { return io.fail(noWindowIsFocused) }
        if shouldFailBecauseFullscreen(window, failIfFullscreen: failIfFullscreen, failIfMacosNativeFullscreen: failIfMacosNativeFullscreen) {
            return ExitCode.fail
        }
        switch window.parent {
            case let parent as TilingContainer:
                guard let indexOfCurrent = window.ownIndex else { return io.fail(internalErrorMessage()) }
                let indexOfSiblingTarget = indexOfCurrent + direction.focusOffset
                if parent.orientation == direction.orientation && parent.children.indices.contains(indexOfSiblingTarget) {
                    if let siblingContainer = parent.children[indexOfSiblingTarget] as? TilingContainer {
                        return deepMoveIn(window, into: siblingContainer, io)
                    }
                    // Swap windows
                    let previousBinding = window.unbindFromParent()
                    window.bind(to: parent, adaptiveWeight: previousBinding.adaptiveWeight, index: indexOfSiblingTarget)
                    return ExitCode.success
                }
                return moveOut(window, context)
            case is FloatingWindowsContainer:
                return io.fail("moving floating windows isn't yet supported")
            case is MacosMinimizedWindowsContainer, is MacosFullscreenWindowsContainer, is MacosHiddenAppsWindowsContainer:
                return io.fail(Self.unconventionalWindowMessage)
            case nil:
                return ExitCode.fail
            default:
                return io.fail(internalErrorMessage())
        }
    }

    private func moveOut(_ window: Window, _ context: CommandContext) -> Int32 {
        let innermostTilingContainer = window.parents.first { node in
            guard let parent = node.parent as? TilingContainer else { return true } // Hit the workspace
            return parent.orientation == direction.orientation
        } as? TilingContainer
        guard let innermostTilingContainer else { return context.io.fail(internalErrorMessage()) }
        switch innermostTilingContainer.parent {
            case let parent as TilingContainer:
                guard let ownIndex = innermostTilingContainer.ownIndex else { return context.io.fail(internalErrorMessage()) }
                window.bind(to: parent, adaptiveWeight: weightAuto, index: ownIndex + direction.insertionOffset)
                return ExitCode.success
            case let workspace as Workspace:
                return hitWorkspaceBoundaries(window, workspace, context)
            default:
                return ExitCode.fail
        }
    }

    private func hitWorkspaceBoundaries(_ window: Window, _ workspace: Workspace, _ context: CommandContext) -> Int32 {
        let world = context.world
        switch boundaries {
            case .workspace:
                return applyBoundariesAction(window, workspace)
            case .allMonitorsOuterFrame:
                guard let workspaceOfWindow = window.nodeWorkspace,
                      let (monitors, index) = world.findRelativeMonitor(from: world.monitor(of: workspaceOfWindow), inDirection: direction)
                else {
                    return context.io.fail("Should never happen. Can't find the current monitor")
                }
                if monitors.indices.contains(index) {
                    var moveNodeToMonitor = MoveNodeToMonitorCommand(rawArgs: [])
                    moveNodeToMonitor.target = .direction(direction)
                    moveNodeToMonitor.common.windowId = window.id
                    moveNodeToMonitor.focusFollowsWindow = world.focus.window === window
                    return moveNodeToMonitor.run(context)
                }
                return applyBoundariesAction(window, workspace)
        }
    }

    private func applyBoundariesAction(_ window: Window, _ workspace: Workspace) -> Int32 {
        switch boundariesAction {
            case .stop:
                return ExitCode.success
            case .fail:
                return ExitCode.fail
            case .createImplicitContainer:
                createImplicitContainerAndMoveWindow(window, workspace)
                return ExitCode.success
        }
    }

    private func createImplicitContainerAndMoveWindow(_ window: Window, _ workspace: Workspace) {
        let previousRoot = workspace.rootTilingContainer
        previousRoot.unbindFromParent()
        // Force tiles layout
        _ = TilingContainer(parent: workspace, adaptiveWeight: weightAuto, direction.orientation, .tiles, index: 0)
        previousRoot.bind(to: workspace.rootTilingContainer, adaptiveWeight: weightAuto, index: 0)
        window.bind(to: workspace.rootTilingContainer, adaptiveWeight: weightAuto, index: direction.insertionOffset)
    }

    private func deepMoveIn(_ window: Window, into container: TilingContainer, _ io: CommandIO) -> Int32 {
        switch findDeepMoveInTarget(container, direction.orientation) {
            case let deepTarget as TilingContainer:
                window.bind(to: deepTarget, adaptiveWeight: weightAuto, index: 0)
            case let deepTarget as Window:
                guard let parent = deepTarget.parent as? TilingContainer, let index = deepTarget.ownIndex else {
                    return io.fail(internalErrorMessage())
                }
                window.bind(to: parent, adaptiveWeight: weightAuto, index: index + 1)
            default:
                return io.fail(internalErrorMessage())
        }
        return ExitCode.success
    }

    /// The first container along `orientation`, descending through most recent children; or the window reached.
    private func findDeepMoveInTarget(_ node: TreeNode, _ orientation: Orientation) -> TreeNode? {
        switch node {
            case is Window: node
            case let container as TilingContainer where container.orientation == orientation: container
            case let container as TilingContainer: container.mostRecentChild.flatMap { findDeepMoveInTarget($0, orientation) }
            default: nil
        }
    }
}
