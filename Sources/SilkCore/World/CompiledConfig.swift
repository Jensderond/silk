import SilkConfig

/// Command scripts of a `Config`, parsed once.
struct CompiledConfig {
    struct WindowDetectedRule {
        let rule: SilkConfig.WindowDetectedRule
        /// The `if = '…'` matcher command.
        let ifCommand: Shell<any Command>?
        let run: Shell<any Command>
    }

    let afterStartupCommand: Shell<any Command>
    let onFocusChanged: Shell<any Command>
    let onFocusedMonitorChanged: Shell<any Command>
    let onModeChanged: Shell<any Command>
    /// Mode name → binding descriptor → commands.
    let bindings: [String: [String: Shell<any Command>]]
    let onWindowDetected: [WindowDetectedRule]
    /// Command parse errors, reported like config errors.
    let diagnostics: [ConfigDiagnostic]

    init(_ config: Config) {
        var diagnostics: [ConfigDiagnostic] = []
        func compile(_ scripts: CommandScripts, keyPath: String) -> Shell<any Command> {
            let shells = scripts.scripts.enumerated().map { index, script in
                let path = scripts.scripts.count > 1 ? "\(keyPath)[\(index)]" : keyPath
                return compileScript(script, keyPath: path, allowExecAndForget: true, diagnostics: &diagnostics)
            }
            return .compound(shells, Shell.seq)
        }

        afterStartupCommand = compile(config.afterStartupCommand, keyPath: "after-startup-command")
        onFocusChanged = compile(config.onFocusChanged, keyPath: "on-focus-changed")
        onFocusedMonitorChanged = compile(config.onFocusedMonitorChanged, keyPath: "on-focused-monitor-changed")
        onModeChanged = compile(config.onModeChanged, keyPath: "on-mode-changed")

        var bindings: [String: [String: Shell<any Command>]] = [:]
        for (modeName, mode) in config.modes.sorted(by: { $0.key < $1.key }) {
            var modeBindings: [String: Shell<any Command>] = [:]
            for (descriptor, binding) in mode.bindings.sorted(by: { $0.key < $1.key }) {
                modeBindings[descriptor] = compile(binding.commands, keyPath: "mode.\(modeName).binding.\(descriptor)")
            }
            bindings[modeName] = modeBindings
        }
        self.bindings = bindings

        onWindowDetected = config.onWindowDetected.enumerated().map { index, rule in
            let path = "on-window-detected[\(index)]"
            let ifCommand = rule.ifCommand.map {
                compileScript($0, keyPath: "\(path).if", allowExecAndForget: false, diagnostics: &diagnostics)
            }
            return WindowDetectedRule(rule: rule, ifCommand: ifCommand, run: compile(rule.run, keyPath: "\(path).run"))
        }
        self.diagnostics = diagnostics
    }
}

private func compileScript(
    _ script: String,
    keyPath: String,
    allowExecAndForget: Bool,
    diagnostics: inout [ConfigDiagnostic]
) -> Shell<any Command> {
    switch CommandRegistry.parse(script: script, allowExecAndForget: allowExecAndForget, allowEval: false) {
        case .cmd(let shell):
            return shell
        case .help(let help):
            diagnostics.append(ConfigDiagnostic(.error, keyPath, help))
        case .failure(let failure):
            diagnostics.append(ConfigDiagnostic(.error, keyPath, failure.message))
    }
    return .empty
}
