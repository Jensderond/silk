/// Turns CLI arguments and shell scripts into commands.
enum CommandRegistry {
    private static let parsers: [String: ([String]) -> ParsedCmd<any Command>] = {
        func entry<C: ParsableCommand>(_: C.Type) -> ([String]) -> ParsedCmd<any Command> {
            { args in C.parse(args).map { $0 as any Command } }
        }
        var result: [String: ([String]) -> ParsedCmd<any Command>] = [:]
        let commands: [any ParsableCommand.Type] = [
            BalanceSizesCommand.self, CloseCommand.self, CloseAllWindowsButCurrentCommand.self, ConfigCommand.self,
            DebugWindowsCommand.self, EchoCommand.self, EnableCommand.self, EvalCommand.self, FalseCommand.self,
            FlattenWorkspaceTreeCommand.self, FocusCommand.self, FocusBackAndForthCommand.self, FocusMonitorCommand.self,
            FullscreenCommand.self, JoinWithCommand.self, LayoutCommand.self, ListAppsCommand.self,
            ListExecEnvVarsCommand.self, ListModesCommand.self, ListMonitorsCommand.self, ListWindowsCommand.self,
            ListWorkspacesCommand.self, MacosNativeFullscreenCommand.self, MacosNativeMinimizeCommand.self,
            ModeCommand.self, MoveCommand.self, MoveMouseCommand.self, MoveNodeToMonitorCommand.self,
            MoveNodeToWorkspaceCommand.self, MoveWorkspaceToMonitorCommand.self, ReloadConfigCommand.self,
            ResizeCommand.self, RunCallbackCommand.self, SplitCommand.self, SummonWorkspaceCommand.self,
            SwapCommand.self, TestCommand.self, TestNotCommand.self, TriggerBindingCommand.self, TrueCommand.self,
            VolumeCommand.self, WorkspaceCommand.self, WorkspaceBackAndForthCommand.self,
        ]
        for command in commands {
            result[command.kind.rawValue] = entry(command)
        }
        // Deprecated aliases
        result["move-through"] = entry(MoveCommand.self)
        result["move-workspace-to-display"] = { args in MoveWorkspaceToMonitorCommand.parseArgs(args).map { $0 as any Command } }
        // `subscribe` streams events; only the IPC server can run it.
        result[CommandKind.subscribe.rawValue] = { args in
            SubscribeArgs.parse(args).flatMap { _ in .failure("subscribe is not supported in the eval") }
        }
        return result
    }()

    /// Parses CLI arguments (`["workspace", "1"]`), as the server does for IPC requests.
    static func parse(args: [String]) -> ParsedCmd<any Command> {
        guard let subcommand = args.first, !subcommand.isEmpty else {
            return .failure("Can't parse empty string command")
        }
        guard let parser = parsers[subcommand] else {
            return .failure("Unrecognized subcommand '\(subcommand)'")
        }
        return parser(Array(args.dropFirst()))
    }

    /// Parses a shell script (config bindings and callbacks, `eval`). A script starting with `exec-and-forget`
    /// is a bash script in its entirety.
    static func parse(script: String, allowExecAndForget: Bool, allowEval: Bool) -> ParsedCmd<Shell<any Command>> {
        if allowExecAndForget && script.hasPrefix(CommandKind.execAndForget.rawValue) {
            return .cmd(.cmd(ExecAndForgetCommand(bashScript: script.removingPrefix(CommandKind.execAndForget.rawValue))))
        }
        switch ShellParser.parse(script) {
            case .failure(let error):
                return .failure(error.message)
            case .success(let shell):
                return shell.flatMap { words in
                    let parsed = parse(args: words)
                    if !allowEval, case .cmd(let command) = parsed, command is EvalCommand {
                        return .failure("Illegal eval (Tip: nested evals are forbidden)")
                    }
                    return parsed
                }
        }
    }
}
