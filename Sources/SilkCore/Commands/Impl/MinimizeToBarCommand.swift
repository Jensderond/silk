/// Silk-only. Collapses a floating window into a bar in the bottom-right corner of its workspace, or brings a
/// collapsed window back. Without `--window-id`, bringing back comes first: after collapsing, focus may land on
/// another floating window, and the second press must still return the first one.
struct MinimizeToBarCommand: ParsableCommand {
    static let kind = CommandKind.minimizeToBar
    static let help = HelpText.minimizeToBar
    static let parser = ArgParser<Self>(flags: ["--window-id": .windowId], positional: [])

    var common: CommonArgs
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        guard let target = context.resolveTarget(common) else { return ExitCode.fail }
        if common.windowId != nil {
            guard let window = target.window else { return context.io.fail(noWindowIsFocused) }
            if window.isCollapsed {
                world.expand(window)
                world.focusWindow(window)
                return ExitCode.success
            }
            return collapse(window, context)
        }
        if let window = target.workspace.collapsedWindows.last {
            world.expand(window)
            world.focusWindow(window)
            return ExitCode.success
        }
        guard let window = target.window else { return context.io.fail(noWindowIsFocused) }
        return collapse(window, context)
    }

    private func collapse(_ window: Window, _ context: CommandContext) -> Int32 {
        guard window.isFloating else {
            return context.io.fail("Only floating windows can be minimized to a bar. Tip: run 'layout floating' first")
        }
        context.world.collapse(window)
        return ExitCode.success
    }
}

extension World {
    /// Takes a floating window off screen and leaves a bar for it. Focus moves to the workspace's most recent
    /// other window.
    func collapse(_ window: Window) {
        guard window.isFloating, let workspace = window.nodeWorkspace else { return }
        let wasFocused = focus.window === window
        window.lastFloatingSize = window.lastKnownFrame?.size ?? window.lastFloatingSize
        window.isFullscreen = false
        window.bind(to: workspace.collapsedWindowsContainer, adaptiveWeight: weightDoesntMatter, index: indexBindLast)
        // Not under the mouse any more (focus-follows-mouse, mouse manipulation)
        window.lastAppliedLayoutPhysicalRect = nil
        window.lastAppliedLayoutVirtualRect = nil
        let next = workspace.mostRecentUncollapsedWindow
        // Keeps the workspace's default focus off the collapsed window
        next?.markAsMostRecentChild()
        if wasFocused { setFocus(LiveFocus(window: next, workspace: workspace)) }
    }

    /// Brings a collapsed window back as a floating window, where it was.
    func expand(_ window: Window) {
        guard window.isCollapsed, let workspace = window.nodeWorkspace else { return }
        bindAsFloatingWindow(window, to: workspace)
    }
}
