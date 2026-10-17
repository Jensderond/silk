/// What AeroSpace shows in the menu bar: the tray text and the workspace list.
public struct MenuBarModel: Equatable, Sendable {
    public struct WorkspaceItem: Equatable, Sendable {
        public var name: String
        /// " - Safari, Terminal" (apps), " - <monitor name>" (visible and empty) or "".
        public var suffix: String
        public var isFocused: Bool
        public var isEffectivelyEmpty: Bool
        public var isVisible: Bool
        public var hasFullscreenWindows: Bool
    }

    /// E.g. `(S) *1 │ 3`: the non-main mode's initial, then each monitor's workspace (left to right); `*` marks the
    /// focused one when there are several monitors, `[…]` a workspace with a fullscreen window.
    public var text: String
    /// The visible workspace of each monitor, in the same left-to-right order as `text`.
    public var visibleWorkspaces: [String]
    public var workspaces: [WorkspaceItem]
    public var mode: String?
    public var isEnabled: Bool

    init(_ world: World) {
        let sortedMonitors = world.sortedMonitors
        let focus = world.focus
        visibleWorkspaces = sortedMonitors.map { world.activeWorkspace(on: $0).name }
        let modePrefix = world.activeMode.flatMap { $0 == mainModeId ? nil : $0.first }.map { "(\(String($0).uppercased())) " } ?? ""
        text = modePrefix + sortedMonitors.map { monitor in
            let workspace = world.activeWorkspace(on: monitor)
            let hasFullscreenWindows = workspace.allLeafWindowsRecursive.contains(where: \.isFullscreen)
            let name = hasFullscreenWindows ? "[\(workspace.name)]" : workspace.name
            return (workspace === focus.workspace && sortedMonitors.count > 1 ? "*" : "") + name
        }.joined(separator: " │ ")
        workspaces = world.allWorkspaces.map { workspace in
            let apps = Set(workspace.allLeafWindowsRecursive.compactMap { $0.appName.flatMap { $0.isEmpty ? nil : $0 } })
            let suffix = if !apps.isEmpty {
                " - " + apps.sorted().joinTruncating(separator: ", ", length: 25)
            } else if world.isVisible(workspace) {
                " - " + world.monitor(of: workspace).name
            } else {
                ""
            }
            return WorkspaceItem(
                name: workspace.name,
                suffix: suffix,
                isFocused: workspace === focus.workspace,
                isEffectivelyEmpty: workspace.isEffectivelyEmpty,
                isVisible: world.isVisible(workspace),
                hasFullscreenWindows: workspace.allLeafWindowsRecursive.contains(where: \.isFullscreen)
            )
        }
        mode = world.activeMode
        isEnabled = world.isEnabled
    }
}
