extension World {
    /// Runs a shell expression. After every command the model is refreshed (workspace GC, focus callbacks,
    /// normalization), as in AeroSpace.
    @discardableResult
    func run(_ shell: Shell<any Command>, env: CommandEnv, io: CommandIO) -> Int32 {
        switch shell {
            case .empty:
                return ExitCode.success
            case .cmd(let command):
                let exitCode = command.run(CommandContext(world: self, env: env, io: io))
                refreshModel()
                return exitCode
            case .and(let shells):
                var exitCode = ExitCode.success
                for shell in shells {
                    exitCode = run(shell, env: env, io: io)
                    if exitCode != ExitCode.success { break }
                }
                return exitCode
            case .or(let shells):
                var exitCode = ExitCode.fail
                for shell in shells {
                    exitCode = run(shell, env: env, io: io)
                    if exitCode == ExitCode.success { break }
                }
                return exitCode
            case .seq(let shells):
                var exitCode = ExitCode.success
                for shell in shells {
                    exitCode = run(shell, env: env, io: io)
                }
                return exitCode
            case .pipe(let shells):
                // Like `set -o pipefail`: stdout is buffered between commands.
                var rightmostNonZeroExitCode = ExitCode.success
                var stageIO = CommandIO(forwardingStdinOf: io)
                var lastStdout: [String] = []
                for shell in shells {
                    let exitCode = run(shell, env: env, io: stageIO)
                    io.stderr += stageIO.stderr
                    lastStdout = stageIO.stdout
                    stageIO = CommandIO(stdin: lastStdout.joined(separator: "\n"))
                    if exitCode != ExitCode.success { rightmostNonZeroExitCode = exitCode }
                }
                io.out(lastStdout)
                return rightmostNonZeroExitCode
        }
    }

    /// Runs a callback script, discarding its output.
    @discardableResult
    func runCallback(_ shell: Shell<any Command>, env: CommandEnv) -> Int32 {
        run(shell, env: env, io: CommandIO(stdin: ""))
    }

    /// AeroSpace `refreshModel`: workspace GC, focus callbacks, container normalization.
    func refreshModel() {
        garbageCollectUnusedWorkspaces()
        checkOnFocusChangedCallbacks()
        for workspace in allWorkspaces {
            workspace.normalizeContainers(
                flatten: config.enableNormalizationFlattenContainers,
                oppositeOrientation: config.enableNormalizationOppositeOrientationForNestedContainers
            )
        }
    }

    /// Compares the focus with the last known one and fires `on-focus-changed`, `exec-on-workspace-change`
    /// and `on-focused-monitor-changed`. Suppressed during startup.
    func checkOnFocusChangedCallbacks() {
        if isStartup { return }
        let focus = self.focus
        let frozenFocus = frozen(focus)
        let lastKnownFocus = self.lastKnownFocus ?? frozenFocus
        var hasFocusChanged = false
        var hasFocusedWorkspaceChanged = false
        var hasFocusedMonitorChanged = false
        if frozenFocus != lastKnownFocus {
            prevFocus = lastKnownFocus
            hasFocusChanged = true
        }
        if frozenFocus.workspaceName != lastKnownFocus.workspaceName {
            prevFocusedWorkspaceName = lastKnownFocus.workspaceName
            hasFocusedWorkspaceChanged = true
        }
        if frozenFocus.monitorId != lastKnownFocus.monitorId {
            hasFocusedMonitorChanged = true
        }
        self.lastKnownFocus = frozenFocus

        if isRunningFocusCallbacks { return }
        isRunningFocusCallbacks = true
        defer { isRunningFocusCallbacks = false }
        if hasFocusChanged {
            onFocusChanged(focus, env: .empty, io: CommandIO(stdin: ""))
        }
        if let prevFocusedWorkspaceName, hasFocusedWorkspaceChanged {
            onWorkspaceChanged(from: prevFocusedWorkspaceName, to: frozenFocus.workspaceName, focus: focus)
        }
        if hasFocusedMonitorChanged {
            onFocusedMonitorChanged(focus, env: .empty, io: CommandIO(stdin: ""))
        }
    }

    @discardableResult
    func onFocusChanged(_ focus: LiveFocus, env: CommandEnv, io: CommandIO) -> Int32 {
        platform.broadcast(.focusChanged(windowId: focus.window?.id, workspace: focus.workspace.name))
        return run(compiledConfig.onFocusChanged, env: env.withFocus(focus), io: io)
    }

    @discardableResult
    func onFocusedMonitorChanged(_ focus: LiveFocus, env: CommandEnv, io: CommandIO) -> Int32 {
        platform.broadcast(.focusedMonitorChanged(
            workspace: focus.workspace.name,
            monitorId: monitorId1Based(monitor(of: focus.workspace)) ?? 0
        ))
        return run(compiledConfig.onFocusedMonitorChanged, env: env.withFocus(focus), io: io)
    }

    private func onWorkspaceChanged(from oldWorkspace: String, to newWorkspace: String, focus: LiveFocus) {
        platform.broadcast(.workspaceChanged(workspace: newWorkspace, prevWorkspace: oldWorkspace))
        guard !config.execOnWorkspaceChange.isEmpty else { return }
        var environment = execEnvironment
        environment[EnvVar.focusedWorkspace] = newWorkspace
        environment[EnvVar.prevWorkspace] = oldWorkspace
        if let window = focus.window {
            environment[EnvVar.workspace] = nil
            environment[EnvVar.windowId] = String(window.id)
        } else {
            environment[EnvVar.workspace] = focus.workspace.name
            environment[EnvVar.windowId] = nil
        }
        // AeroSpace runs the executable directly; `exec` makes bash replace itself with it.
        let script = "exec " + config.execOnWorkspaceChange.map(\.shellQuoted).joined(separator: " ")
        _ = platform.execAndForget(script, env: environment)
    }

    /// `exec-and-forget`: the `[exec]` environment plus the `AEROSPACE_*` variables of `env`.
    func execAndForget(_ script: String, env: CommandEnv) -> Bool {
        platform.execAndForget(script, env: execEnvironment.merging(env.environmentVariables) { _, new in new })
    }

    /// Runs `on-window-detected` rules for a window. Returns the exit code of the last rule run.
    @discardableResult
    func onWindowDetected(_ window: Window, env: CommandEnv, io: CommandIO) -> Int32 {
        platform.broadcast(.windowDetected(
            windowId: window.id,
            workspace: window.nodeWorkspace?.name,
            appBundleId: window.bundleId,
            appName: window.appName
        ))
        // AeroSpace quirk kept for exit-code parity: with no matching rule the result is 2.
        var lastExitCode = ExitCode.fail
        for rule in compiledConfig.onWindowDetected where matches(rule, window) {
            lastExitCode = run(rule.run, env: env.withWindowId(window.id), io: io)
            if !rule.rule.checkFurtherCallbacks { return lastExitCode }
        }
        return lastExitCode
    }

    func matches(_ compiled: CompiledConfig.WindowDetectedRule, _ window: Window) -> Bool {
        if let ifCommand = compiled.ifCommand {
            return runCallback(ifCommand, env: CommandEnv.empty.withWindowId(window.id)) == ExitCode.success
        }
        let matcher = compiled.rule.matcher
        if let duringStartup = matcher.duringStartup, duringStartup != isStartup { return false }
        if let regex = matcher.windowTitleRegexSubstring, !regexes.matches(window.title, pattern: regex) { return false }
        if let appId = matcher.appId, appId != window.bundleId { return false }
        if let regex = matcher.appNameRegexSubstring, !regexes.matches(window.appName ?? "", pattern: regex) { return false }
        if let workspace = matcher.workspace, workspace != window.nodeWorkspace?.name { return false }
        return true
    }

    /// Runs `on-window-detected` for tiled, floating and macOS-special windows (not popups), applying a pending
    /// `layout --for-next-detected-window` before and after the rules.
    func runOnWindowDetected(ifConventional window: Window) {
        guard window.parent != nil, !(window.parent is MacosPopupWindowsContainer) else { return }
        let layout = layoutForNextDetectedWindow
        layoutForNextDetectedWindow = nil
        let env = CommandEnv.empty.withWindowId(window.id)
        if let layout { runCallback(.cmd(LayoutCommand(toggleBetween: [layout])), env: env) }
        onWindowDetected(window, env: .empty, io: CommandIO(stdin: ""))
        if let layout { runCallback(.cmd(LayoutCommand(toggleBetween: [layout])), env: env) }
    }

    /// Switches the binding mode; `nil` deactivates all bindings (disabled).
    func activateMode(_ targetMode: String?) {
        let oldMode = activeMode
        activeMode = targetMode
        observer?.worldDidActivateMode(targetMode)
        if oldMode != targetMode {
            platform.broadcast(.modeChanged(mode: targetMode))
            runCallback(compiledConfig.onModeChanged, env: .empty)
        }
    }
}

extension CommandEnv {
    /// Targets the focused window, or the workspace when it's empty.
    func withFocus(_ focus: LiveFocus) -> CommandEnv {
        if let window = focus.window { withWindowId(window.id) } else { withWorkspace(focus.workspace.name) }
    }
}

extension String {
    /// Single-quoted for bash.
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
