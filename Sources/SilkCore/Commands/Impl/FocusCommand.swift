import CoreGraphics

struct FocusCommand: ParsableCommand {
    enum Boundaries: String, CaseIterable {
        case workspace
        case allMonitorsOuterFrame = "all-monitors-outer-frame"
    }

    enum WhenBoundariesCrossed: String, CaseIterable {
        case stop
        case fail
        case wrapAroundTheWorkspace = "wrap-around-the-workspace"
        case wrapAroundAllMonitors = "wrap-around-all-monitors"
    }

    enum Target {
        case direction(CardinalDirection)
        case windowId(WindowID)
        case dfsIndex(UInt32)
        case dfsRelative(DfsNextPrev)
    }

    static let kind = CommandKind.focus
    static let help = HelpText.focus
    static let parser = ArgParser<Self>(
        flags: [
            "--ignore-floating": .falseBool(\.floatingAsTiling),
            "--window-id": .windowId,
            "--dfs-index": .single(\.dfsIndex, "<dfs-index>", parseUInt32),
            "--boundaries": .value(\.rawBoundaries, parseEnumFlag(Boundaries.self, missing: "<boundary>")),
            "--boundaries-action": .value(\.rawBoundariesAction, parseEnumFlag(WhenBoundariesCrossed.self, missing: "<action>")),
            "--fail-if-fullscreen": .trueBool(\.failIfFullscreen),
            "--fail-if-macos-native-fullscreen": .trueBool(\.failIfMacosNativeFullscreen),
            "--wrap-around": .trueBool(\.wrapAroundAlias),
        ],
        positional: [.value(\.cardinalOrDfsDirection) { input in
            ParsedArg(value: parseEnum(input.arg, CardinalOrDfsDirection.self).map(Optional.some), advanceBy: 1)
        }],
        conflictingOptions: [
            ["--wrap-around", "--boundaries-action"],
            ["--wrap-around", "--boundaries"],
        ]
    )

    var common: CommonArgs
    var rawBoundaries: Boundaries?
    var rawBoundariesAction: WhenBoundariesCrossed?
    var failIfFullscreen = false
    var failIfMacosNativeFullscreen = false
    var wrapAroundAlias = false
    var dfsIndex: UInt32?
    var cardinalOrDfsDirection: CardinalOrDfsDirection?
    var floatingAsTiling = true
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    var boundaries: Boundaries { rawBoundaries ?? .workspace }
    var boundariesAction: WhenBoundariesCrossed { wrapAroundAlias ? .wrapAroundTheWorkspace : (rawBoundariesAction ?? .stop) }

    var target: Target {
        if let cardinalOrDfsDirection {
            switch cardinalOrDfsDirection {
                case .direction(let direction): return .direction(direction)
                case .dfsRelative(let nextPrev): return .dfsRelative(nextPrev)
            }
        }
        if let windowId = common.windowId { return .windowId(windowId) }
        return .dfsIndex(dfsIndex ?? 0)
    }

    static func parse(_ args: [String]) -> ParsedCmd<FocusCommand> {
        parseArgs(args)
            .flatMap { raw in
                raw.boundaries == .workspace && raw.boundariesAction == .wrapAroundAllMonitors
                    ? .failure("\(raw.boundaries.rawValue) and \(raw.boundariesAction.rawValue) is an invalid combination of values")
                    : .cmd(raw)
            }
            .filter("Mandatory argument is missing. \(CardinalOrDfsDirection.unionLiteral), --window-id or --dfs-index is required") {
                $0.cardinalOrDfsDirection != nil || $0.common.windowId != nil || $0.dfsIndex != nil
            }
            .filter("--window-id is incompatible with other options") {
                $0.common.windowId == nil || $0.hasOnlyDefaults(except: \.common.windowId)
            }
            .filter("--dfs-index is incompatible with other options") {
                $0.dfsIndex == nil || $0.hasOnlyDefaults(except: \.dfsIndex)
            }
            .filter("--fail-if-fullscreen/--fail-if-macos-native-fullscreen require using (left|down|up|right) argument") {
                guard $0.failIfFullscreen || $0.failIfMacosNativeFullscreen else { return true }
                if case .direction = $0.target { return true }
                return false
            }
            .filter("(dfs-next|dfs-prev) only supports --boundaries workspace") {
                if case .dfsRelative = $0.target { return $0.boundaries == .workspace }
                return true
            }
    }

    /// True if every option except the one at `keyPath` has its default value.
    private func hasOnlyDefaults<V>(except keyPath: WritableKeyPath<FocusCommand, V?>) -> Bool {
        var defaults = FocusCommand(rawArgs: common.rawArgs)
        defaults[keyPath: keyPath] = self[keyPath: keyPath]
        return defaults.common == common && defaults.rawBoundaries == rawBoundaries
            && defaults.rawBoundariesAction == rawBoundariesAction && defaults.failIfFullscreen == failIfFullscreen
            && defaults.failIfMacosNativeFullscreen == failIfMacosNativeFullscreen && defaults.wrapAroundAlias == wrapAroundAlias
            && defaults.dfsIndex == dfsIndex && defaults.cardinalOrDfsDirection == cardinalOrDfsDirection
            && defaults.floatingAsTiling == floatingAsTiling
    }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        let io = context.io
        guard let focus = context.resolveTarget(common) else { return ExitCode.fail }
        if let window = focus.window,
           shouldFailBecauseFullscreen(window, failIfFullscreen: failIfFullscreen, failIfMacosNativeFullscreen: failIfMacosNativeFullscreen)
        {
            return ExitCode.fail
        }
        let floatingWindows = floatingAsTiling ? makeFloatingWindowsSeenAsTiling(focus.workspace, world) : []
        defer {
            if floatingAsTiling { restoreFloatingWindows(floatingWindows, focus.workspace) }
        }

        switch target {
            case .direction(let direction):
                if let (parent, ownIndex) = focus.window?.closestParent(hasChildrenInDirection: direction, withLayout: nil) {
                    guard let windowToFocus = parent.children[ownIndex + direction.focusOffset].findLeafWindowRecursive(snappedTo: direction.opposite)
                    else { return io.fail(internalErrorMessage()) }
                    return ExitCode.from(world.focusWindow(windowToFocus))
                }
                return hitWorkspaceBoundaries(focus, direction, context)
            case .windowId(let windowId):
                guard let windowToFocus = world.window(byId: windowId) else { return io.fail("Can't find window with ID \(windowId)") }
                return ExitCode.from(world.focusWindow(windowToFocus))
            case .dfsIndex(let dfsIndex):
                guard let windowToFocus = focus.workspace.rootTilingContainer.allLeafWindowsRecursive.element(at: Int(dfsIndex)) else {
                    return io.fail("Can't find window with DFS index \(dfsIndex)")
                }
                return ExitCode.from(world.focusWindow(windowToFocus))
            case .dfsRelative(let nextPrev):
                let windows = focus.workspace.rootTilingContainer.allLeafWindowsRecursive
                guard let currentIndex = windows.firstIndex(where: { $0 === focus.window }) else { return ExitCode.fail }
                var targetIndex = nextPrev == .dfsNext ? currentIndex + 1 : currentIndex - 1
                if !windows.indices.contains(targetIndex) {
                    switch boundariesAction {
                        case .stop: return ExitCode.success
                        case .fail: return ExitCode.fail
                        case .wrapAroundTheWorkspace: targetIndex = (targetIndex + windows.count) % windows.count
                        case .wrapAroundAllMonitors: return io.fail(internalErrorMessage("Must be discarded by args parser"))
                    }
                }
                return ExitCode.from(world.focusWindow(windows[targetIndex]))
        }
    }

    private func hitWorkspaceBoundaries(_ focus: LiveFocus, _ direction: CardinalDirection, _ context: CommandContext) -> Int32 {
        let world = context.world
        switch boundaries {
            case .workspace:
                switch boundariesAction {
                    case .stop: return ExitCode.success
                    case .fail: return ExitCode.fail
                    case .wrapAroundTheWorkspace: return wrapAroundTheWorkspace(focus, direction, context)
                    case .wrapAroundAllMonitors: return context.io.fail("Must be discarded by args parser")
                }
            case .allMonitorsOuterFrame:
                let currentMonitor = world.monitor(of: focus.workspace)
                guard let (monitors, index) = world.findRelativeMonitor(from: currentMonitor, inDirection: direction) else {
                    return context.io.fail(internalErrorMessage("Should never happen. Can't find the current monitor"))
                }
                if let targetMonitor = monitors.element(at: index) {
                    return ExitCode.from(world.focusWorkspace(world.activeWorkspace(on: targetMonitor)))
                }
                guard let wrapped = monitors.element(wrappingIndex: index) else { return context.io.fail(internalErrorMessage()) }
                switch boundariesAction {
                    case .stop: return ExitCode.success
                    case .fail: return ExitCode.fail
                    case .wrapAroundTheWorkspace: return wrapAroundTheWorkspace(focus, direction, context)
                    case .wrapAroundAllMonitors:
                        let workspace = world.activeWorkspace(on: wrapped)
                        workspace.findLeafWindowRecursive(snappedTo: direction.opposite)?.markAsMostRecentChild()
                        return ExitCode.from(world.focusWorkspace(workspace))
                }
        }
    }

    private func wrapAroundTheWorkspace(_ focus: LiveFocus, _ direction: CardinalDirection, _ context: CommandContext) -> Int32 {
        guard let windowToFocus = focus.workspace.findLeafWindowRecursive(snappedTo: direction.opposite) else {
            return context.io.fail(noWindowIsFocused)
        }
        return ExitCode.from(context.world.focusWindow(windowToFocus))
    }
}

private struct FloatingWindowData {
    let window: Window
    let center: CGPoint
    let tilingParent: TilingContainer
    let adaptiveWeight: CGFloat
    let index: Int
}

/// Temporarily binds floating windows into the tiling tree where their centers are, so directional focus
/// can reach them.
private func makeFloatingWindowsSeenAsTiling(_ workspace: Workspace, _ world: World) -> [FloatingWindowData] {
    let mruBefore = workspace.mostRecentWindowRecursive
    defer { mruBefore?.markAsMostRecentChild() }
    var result: [FloatingWindowData] = []
    for window in workspace.floatingWindows {
        guard let center = window.lastKnownFrame?.center else { continue }
        let tilingParent: TilingContainer
        let index: Int
        if let target = center.coerced(in: world.visibleRectPaddedByOuterGaps(world.monitor(of: workspace)))?
            .findWindowRecursively(in: workspace.rootTilingContainer, virtual: true, fullscreenCoversAll: false)
        {
            guard let targetCenter = target.lastKnownFrame?.center ?? target.lastAppliedLayoutPhysicalRect?.center,
                  let parent = target.parent as? TilingContainer, let targetIndex = target.ownIndex else { continue }
            tilingParent = parent
            let isAfter = center.projection(parent.orientation) >= targetCenter.projection(parent.orientation)
            index = switch parent.layout {
                case .tiles: isAfter ? targetIndex + 1 : targetIndex
                case .accordion: isAfter ? parent.children.count : 0
            }
        } else {
            index = 0
            tilingParent = workspace.rootTilingContainer
        }
        let data = window.unbindFromParent()
        result.append(FloatingWindowData(window: window, center: center, tilingParent: tilingParent, adaptiveWeight: data.adaptiveWeight, index: index))
    }
    let sorted = result.sorted { $0.center.projection($0.tilingParent.orientation) < $1.center.projection($1.tilingParent.orientation) }.reversed()
    for floating in sorted {
        floating.window.bind(to: floating.tilingParent, adaptiveWeight: 1, index: floating.index)
    }
    return Array(sorted)
}

private func restoreFloatingWindows(_ floatingWindows: [FloatingWindowData], _ workspace: Workspace) {
    let mruBefore = workspace.mostRecentWindowRecursive
    defer { mruBefore?.markAsMostRecentChild() }
    for floating in floatingWindows {
        floating.window.bind(to: workspace.floatingWindowsContainer, adaptiveWeight: floating.adaptiveWeight, index: indexBindLast)
    }
}

func shouldFailBecauseFullscreen(_ window: Window, failIfFullscreen: Bool, failIfMacosNativeFullscreen: Bool) -> Bool {
    (failIfFullscreen && window.isFullscreen) || (failIfMacosNativeFullscreen && window.isMacosFullscreen)
}
