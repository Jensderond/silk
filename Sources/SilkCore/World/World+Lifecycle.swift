import SilkConfig

struct ReloadConfigResult {
    let isOk: Bool
    let stdout: String
    let stderr: String
}

extension World {
    /// AeroSpace `reloadConfig`: re-reads the config through the platform, reports errors/warnings and applies
    /// it unless it's fatally broken or `dryRun`. Errors go to stdout and warnings to stderr, as in AeroSpace.
    func reloadConfig(noGui: Bool, dryRun: Bool, warningsAsErrors: Bool) -> ReloadConfigResult {
        let result = platform.reloadConfig()
        let compiled = CompiledConfig(result.config)
        let diagnostics = result.diagnostics + compiled.diagnostics
        var errors = diagnostics.filter { $0.severity == .error }.map(\.description)
        var warnings = diagnostics.filter { $0.severity == .warning }.map(\.description)
        let path = (result.url ?? configURL)?.absoluteURL.path.singleQuoted ?? "''"

        if !noGui {
            let lines = (errors + warnings).joined(separator: "\n\n")
            if !errors.isEmpty {
                observer?.worldDidChangeConfigMessage(
                    "Failed to parse \(path). \(errors.count) error(s). \(warnings.count) warning(s)\n\n\(lines)"
                )
            } else if warningsAsErrors && !warnings.isEmpty {
                observer?.worldDidChangeConfigMessage(
                    "Parsed \(path) with \(warnings.count) warning(s). Feel free to close this window.\n\n\(lines)"
                )
            } else {
                observer?.worldDidChangeConfigMessage(nil)
            }
        }
        if !result.isFatal && !dryRun {
            applyConfig(result.config)
            if let url = result.url { configURL = url }
            activateMode(activeMode)
            observer?.worldDidReloadConfig(result.config)
        }
        if warningsAsErrors {
            errors += warnings
            warnings = []
        }
        return ReloadConfigResult(isOk: errors.isEmpty, stdout: errors.joined(separator: "\n\n"), stderr: warnings.joined(separator: "\n\n"))
    }

    /// `enable on|off`. While disabled no bindings are active and new windows are only queued.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            for workspace in allWorkspaces {
                for window in workspace.allLeafWindowsRecursive where window.isFloating {
                    window.lastFloatingSize = window.lastKnownFrame?.size ?? window.lastFloatingSize
                }
            }
            activateMode(mainModeId)
            let queued = detectionsWhileDisabled
            detectionsWhileDisabled = []
            for detected in queued {
                let window = register(detected, bindByMonitorUnderCenter: false)
                if detected.isFocused { syncFocusFromNative(window) }
            }
        } else {
            activateMode(nil)
        }
        observer?.worldDidChangeEnabled(enabled)
    }
}
