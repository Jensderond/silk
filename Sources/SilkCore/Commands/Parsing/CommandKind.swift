/// Every AeroSpace subcommand.
enum CommandKind: String, CaseIterable {
    case balanceSizes = "balance-sizes"
    case close
    case closeAllWindowsButCurrent = "close-all-windows-but-current"
    case config
    case debugWindows = "debug-windows"
    case echo
    case enable
    case eval
    case execAndForget = "exec-and-forget"
    case _false = "false"
    case flattenWorkspaceTree = "flatten-workspace-tree"
    case focus
    case focusBackAndForth = "focus-back-and-forth"
    case focusMonitor = "focus-monitor"
    case fullscreen
    case joinWith = "join-with"
    case layout
    case listApps = "list-apps"
    case listExecEnvVars = "list-exec-env-vars"
    case listModes = "list-modes"
    case listMonitors = "list-monitors"
    case listWindows = "list-windows"
    case listWorkspaces = "list-workspaces"
    case macosNativeFullscreen = "macos-native-fullscreen"
    case macosNativeMinimize = "macos-native-minimize"
    case mode
    case move
    case moveMouse = "move-mouse"
    case moveNodeToMonitor = "move-node-to-monitor"
    case moveNodeToWorkspace = "move-node-to-workspace"
    case moveWorkspaceToMonitor = "move-workspace-to-monitor"
    case reloadConfig = "reload-config"
    case resize
    case runCallback = "run-callback"
    case split
    case subscribe
    case summonWorkspace = "summon-workspace"
    case swap
    case test
    case testNot = "test-not"
    case triggerBinding = "trigger-binding"
    case _true = "true"
    case volume
    case workspace
    case workspaceBackAndForth = "workspace-back-and-forth"

    /// Commands that only read state; running them doesn't invalidate the layout.
    var isQuery: Bool {
        switch self {
            case .config, .debugWindows, .echo, ._false, .listApps, .listExecEnvVars, .listModes, .listMonitors,
                 .listWindows, .listWorkspaces, .subscribe, .test, .testNot, ._true:
                true
            default:
                false
        }
    }
}
