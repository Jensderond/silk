// `--help` output of every command, verbatim from AeroSpace's cmdHelpGenerated.swift.
enum HelpText {
    static let balanceSizes = """
        USAGE: balance-sizes [-h|--help] [--workspace <workspace>]
        """
    static let closeAllWindowsButCurrent = """
        USAGE: close-all-windows-but-current [-h|--help] [--quit-if-last-window]
        """
    static let close = """
        USAGE: close [-h|--help] [--quit-if-last-window] [--window-id <window-id>]
        """
    static let config = """
        USAGE: config [-h|--help] --get <name> [--json] [--keys]
           OR: config [-h|--help] --major-keys
           OR: config [-h|--help] --all-keys
           OR: config [-h|--help] --config-path
        """
    static let debugWindows = """
        USAGE: debug-windows [-h|--help] [--window-id <window-id>]
        """
    static let echo = """
        USAGE: echo [-h|--help] [--stderr] [--window-id <window-id>] -- <string>...
        """
    static let enable = """
        USAGE: enable [-h|--help] toggle
           OR: enable [-h|--help] on [--fail-if-noop]
           OR: enable [-h|--help] off [--fail-if-noop]
        """
    static let eval = """
        USAGE: eval [-h|--help] [--stdin] [--] <aerospace-shell-expr>
        """
    static let execAndForget = """
        USAGE: exec-and-forget <bash-script>
        """
    static let _false = """
        USAGE: false [-h|--help]
        """
    static let flattenWorkspaceTree = """
        USAGE: flatten-workspace-tree [-h|--help] [--workspace <workspace>]
        """
    static let focusBackAndForth = """
        USAGE: focus-back-and-forth [-h|--help]
        """
    static let focusMonitor = """
        USAGE: focus-monitor [-h|--help] [--wrap-around] (left|down|up|right)
           OR: focus-monitor [-h|--help] [--wrap-around] (next|prev)
           OR: focus-monitor [-h|--help] [--] <monitor-pattern>...
        """
    static let focus = """
        USAGE: focus [-h|--help] [--ignore-floating] [--wrap-around]
                     [--boundaries <boundary>] [--boundaries-action <action>]
                     [--fail-if-fullscreen] [--fail-if-macos-native-fullscreen]
                     (left|down|up|right)
           OR: focus [-h|--help] [--ignore-floating] [--wrap-around]
                     [--boundaries <boundary>] [--boundaries-action <action>]
                     (dfs-next|dfs-prev)
           OR: focus [-h|--help] --window-id <window-id>
           OR: focus [-h|--help] --dfs-index <dfs-index>
        """
    static let fullscreen = """
        USAGE: fullscreen [-h|--help]     [--window-id <window-id>] [--no-outer-gaps]
           OR: fullscreen [-h|--help] on  [--window-id <window-id>] [--no-outer-gaps] [--fail-if-noop]
           OR: fullscreen [-h|--help] off [--window-id <window-id>] [--fail-if-noop]
        """
    static let joinWith = """
        USAGE: join-with [-h|--help] [--window-id <window-id>] (left|down|up|right)
        """
    static let layout = """
        USAGE: layout [-h|--help] [--window-id <window-id>|--workspace <workspace>]
                      [--root] [--fail-if-noop]
                      (<target-layout>)...
           OR: layout [-h|--help] --for-next-detected-window (tiling|floating)
        """
    static let listApps = """
        USAGE: list-apps [-h|--help] [--macos-native-hidden [no]] [--format <output-format>] [--count] [--json]
        """
    static let listExecEnvVars = """
        USAGE: list-exec-env-vars [-h|--help]
        """
    static let listModes = """
        USAGE: list-modes [-h|--help] [--current] [--count] [--json]
        """
    static let listMonitors = """
        USAGE: list-monitors [-h|--help] [--focused [no]] [--mouse [no]] [--format <output-format>] [--count] [--json]
        """
    static let listWindows = """
        USAGE: list-windows [-h|--help] (--workspace <workspace>...|--monitor <monitor>...)
                            [--monitor <monitor>...] [--workspace <workspace>...]
                            [--pid <pid>] [--app-bundle-id <app-bundle-id>] [--format <output-format>]
                            [--count] [--json]
           OR: list-windows [-h|--help] --all [--format <output-format>] [--count] [--json]
           OR: list-windows [-h|--help] --focused [--format <output-format>] [--count] [--json]
        """
    static let listWorkspaces = """
        USAGE: list-workspaces [-h|--help] --monitor <monitor>... [--visible [no]] [--empty [no]] [--format <output-format>] [--count] [--json]
           OR: list-workspaces [-h|--help] --all [--format <output-format>] [--count] [--json]
           OR: list-workspaces [-h|--help] --focused [--format <output-format>] [--count] [--json]
        """
    static let macosNativeFullscreen = """
        USAGE: macos-native-fullscreen [-h|--help] [--window-id <window-id>]
           OR: macos-native-fullscreen [-h|--help] [--window-id <window-id>] [--fail-if-noop] on
           OR: macos-native-fullscreen [-h|--help] [--window-id <window-id>] [--fail-if-noop] off
        """
    static let macosNativeMinimize = """
        USAGE: macos-native-minimize [-h|--help] [--window-id <window-id>]
        """
    static let mode = """
        USAGE: mode [-h|--help] [--] <binding-mode>
        """
    static let moveMouse = """
        USAGE: move-mouse [-h|--help] [--fail-if-noop] <mouse-position>
        """
    static let moveNodeToMonitor = """
        USAGE: move-node-to-monitor [-h|--help] [--window-id <window-id>] [--focus-follows-window]
                                    [--wrap-around] (left|down|up|right|next|prev)
           OR: move-node-to-monitor [-h|--help] [--window-id <window-id>] [--focus-follows-window]
                                    [--fail-if-noop] [--] <monitor-pattern>...
        """
    static let moveNodeToWorkspace = """
        USAGE: move-node-to-workspace [-h|--help] [--focus-follows-window] [--wrap-around]
                                      [--stdin|--no-stdin]
                                      (next|prev)
           OR: move-node-to-workspace [-h|--help] [--focus-follows-window] [--fail-if-noop]
                                      [--window-id <window-id>] [--] <workspace-name>
        """
    static let moveWorkspaceToMonitor = """
        USAGE: move-workspace-to-monitor [-h|--help] [--workspace <workspace>] [--wrap-around] (left|down|up|right)
           OR: move-workspace-to-monitor [-h|--help] [--workspace <workspace>] [--wrap-around] (next|prev)
           OR: move-workspace-to-monitor [-h|--help] [--workspace <workspace>] [--] <monitor-pattern>...
        """
    static let move = """
        USAGE: move [-h|--help] [--window-id <window-id>] [--boundaries <boundary>]
                    [--boundaries-action <boundary-action>] [--fail-if-fullscreen]
                    [--fail-if-macos-native-fullscreen] (left|down|up|right)
        """
    static let reloadConfig = """
        USAGE: reload-config [-h|--help] [--no-gui] [--dry-run] [--warnings-as-errors]
        """
    static let resize = """
        USAGE: resize [-h|--help] [--window-id <window-id>] (smart|smart-opposite|width|height) [+|-]<number>
        """
    static let runCallback = """
        USAGE: run-callback [-h|--help] [--for-every-window|--window-id <window-id>] on-window-detected
           OR: run-callback [-h|--help] (on-focus-changed|on-focused-monitor-changed)
        """
    static let split = """
        USAGE: split [-h|--help] [--window-id <window-id>] (horizontal|vertical|opposite)
        """
    static let subscribe = """
        USAGE: subscribe [-h|--help] [--all] [--no-send-initial] [<event>...]
        """
    static let summonWorkspace = """
        USAGE: summon-workspace [-h|--help] [--fail-if-noop] [--] <workspace>
        """
    static let swap = """
        USAGE: swap [-h|--help] [--window-id <window-id>] [--swap-focus]
                    [--wrap-around] (left|down|up|right|dfs-next|dfs-prev)
        """
    static let testNot = """
        USAGE: test-not [-h|--help] <lhs> = <rhs>
           OR: test-not [-h|--help] <lhs> ~= <rhs>
        """
    static let test = """
        USAGE: test [-h|--help] <lhs> = <rhs>
           OR: test [-h|--help] <lhs> ~= <rhs>
        """
    static let triggerBinding = """
        USAGE: trigger-binding [-h|--help] --mode <mode-id> [--] <binding>
        """
    static let _true = """
        USAGE: true [-h|--help]
        """
    static let volume = """
        USAGE: volume [-h|--help] (up|down) [--no-gui]
           OR: volume [-h|--help] (mute-toggle|mute-off|mute-on) [--no-gui]
           OR: volume [-h|--help] set <number> [--no-gui]
        """
    static let workspaceBackAndForth = """
        USAGE: workspace-back-and-forth [-h|--help]
        """
    static let workspace = """
        USAGE: workspace [-h|--help] [--auto-back-and-forth] [--fail-if-noop] [--] <workspace-name>
           OR: workspace [-h|--help] [--wrap-around] [--stdin|--no-stdin] (next|prev)
        """
}
