extension WindowManager {
    static let disabledMessage =
        "Silk server is disabled and doesn't accept commands. You can use 'aerospace enable on' to enable the server"

    /// Runs a command given as CLI arguments (`["move-node-to-workspace", "3"]`), as received over IPC.
    /// `stdin` is the client's stdin; `env` carries the client's `AEROSPACE_WINDOW_ID` / `AEROSPACE_WORKSPACE`.
    public func run(args: [String], stdin: String = "", env: CommandEnv = .empty) -> CommandResult {
        let parsed = CommandRegistry.parse(args: args)
        if !world.isEnabled && !(parsed.cmdOrNil is EnableCommand) {
            return CommandResult(exitCode: ExitCode.fail, stderr: Self.disabledMessage)
        }
        switch parsed {
            case .help(let help):
                return CommandResult(exitCode: ExitCode.success, stdout: help)
            case .failure(let failure):
                return CommandResult(exitCode: failure.exitCode, stderr: failure.message)
            case .cmd(let command):
                return run(.cmd(command), stdin: stdin, env: env)
        }
    }

    /// Runs a shell script in AeroSpace's syntax (`;`, `&&`, `||`, `|`, parentheses), as in config bindings.
    /// A script starting with `exec-and-forget` is a bash script.
    public func run(script: String, env: CommandEnv = .empty) -> CommandResult {
        let parsed = CommandRegistry.parse(script: script, allowExecAndForget: true, allowEval: false)
        if !world.isEnabled && !((parsed.cmdOrNil?.commands.first) is EnableCommand) {
            return CommandResult(exitCode: ExitCode.fail, stderr: Self.disabledMessage)
        }
        switch parsed {
            case .help(let help):
                return CommandResult(exitCode: ExitCode.success, stdout: help)
            case .failure(let failure):
                return CommandResult(exitCode: failure.exitCode, stderr: failure.message)
            case .cmd(let shell):
                return run(shell, stdin: "", env: env)
        }
    }

    /// A hotkey of the active mode was pressed: broadcasts `binding-triggered` and runs the binding.
    /// Returns nil if the active mode has no such binding.
    @discardableResult
    public func handleHotkey(_ descriptor: String) -> CommandResult? {
        guard world.isEnabled, let mode = world.activeMode, let shell = world.compiledConfig.bindings[mode]?[descriptor] else {
            return nil
        }
        world.platform.broadcast(.bindingTriggered(mode: mode, binding: descriptor))
        return run(shell, stdin: "", env: .empty)
    }

    private func run(_ shell: Shell<any Command>, stdin: String, env: CommandEnv) -> CommandResult {
        let mutates = shell.commands.contains { !$0.kind.isQuery }
        return commandSession(mutates: mutates) {
            let io = CommandIO(stdin: stdin)
            let exitCode = world.run(shell, env: env, io: io)
            return CommandResult(exitCode: exitCode, stdout: io.stdout.joined(separator: "\n"), stderr: io.stderr.joined(separator: "\n"))
        }
    }

    // MARK: subscribe

    /// Parses `subscribe` arguments (the IPC server streams events itself).
    public static func parseSubscribe(args: [String]) -> SubscribeParseResult {
        switch SubscribeArgs.parse(args) {
            case .cmd(let parsed): .subscribe(events: parsed.events, sendInitial: parsed.sendInitial)
            case .help(let help): .help(help)
            case .failure(let failure): .failure(message: failure.message, exitCode: failure.exitCode)
        }
    }

    /// The events sent right after subscribing when `sendInitial` (AeroSpace sends the current state).
    public func initialSubscribeEvents(for events: Set<ServerEventType>) -> [ServerEvent] {
        let focus = world.focus
        return ServerEventType.allCases.filter(events.contains).compactMap { type in
            switch type {
                case .focusChanged:
                    .focusChanged(windowId: focus.window?.id, workspace: focus.workspace.name)
                case .workspaceChanged:
                    .workspaceChanged(workspace: focus.workspace.name, prevWorkspace: focus.workspace.name)
                case .modeChanged:
                    .modeChanged(mode: world.activeMode)
                case .focusedMonitorChanged:
                    .focusedMonitorChanged(workspace: focus.workspace.name, monitorId: world.monitorId1Based(world.monitor(of: focus.workspace)) ?? 0)
                case .windowDetected, .bindingTriggered:
                    nil
            }
        }
    }
}

/// The outcome of parsing `subscribe` arguments.
public enum SubscribeParseResult: Equatable, Sendable {
    case subscribe(events: Set<ServerEventType>, sendInitial: Bool)
    /// `--help`: print and exit 0.
    case help(String)
    case failure(message: String, exitCode: Int32)
}
