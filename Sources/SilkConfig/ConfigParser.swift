import Foundation

/// Turns the raw TOML tree into a `Config`, collecting AeroSpace-style diagnostics. Invalid values are reported
/// and skipped (the field keeps its default) so one typo never discards the rest of the config.
struct ConfigParser {
    private(set) var diagnostics: [ConfigDiagnostic] = []

    var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }

    mutating func error(_ path: ConfigKeyPath, _ message: String) {
        diagnostics.append(ConfigDiagnostic(.error, path.description, message))
    }

    mutating func warning(_ path: ConfigKeyPath, _ message: String) {
        diagnostics.append(ConfigDiagnostic(.warning, path.description, message))
    }

    mutating func absorb(_ other: ConfigParser) {
        diagnostics += other.diagnostics
    }

    mutating func unknownKey(_ path: ConfigKeyPath) {
        error(path, path.isTopLevelKey ? "Unknown top-level key" : "Unknown key")
    }

    mutating func typeMismatch(expected: [TOMLType], actual: TOMLType, _ path: ConfigKeyPath) {
        let message = if let single = expected.first, expected.count == 1 {
            "Expected type is '\(single.rawValue)'. But actual type is '\(actual.rawValue)'"
        } else {
            "Expected types are \(expected.map { "'\($0.rawValue)'" }.joined(separator: " or ")). But actual type is '\(actual.rawValue)'"
        }
        error(path, message)
    }

    // MARK: Typed accessors (report a type mismatch and return nil on failure)

    mutating func bool(_ value: TOMLValue, _ path: ConfigKeyPath) -> Bool? {
        if case .bool(let bool) = value { return bool }
        typeMismatch(expected: [.bool], actual: value.type, path)
        return nil
    }

    mutating func int(_ value: TOMLValue, _ path: ConfigKeyPath) -> Int? {
        if case .int(let int) = value { return int }
        typeMismatch(expected: [.int], actual: value.type, path)
        return nil
    }

    /// Accepts both TOML integers and floats.
    mutating func number(_ value: TOMLValue, _ path: ConfigKeyPath) -> Double? {
        switch value {
            case .int(let int): return Double(int)
            case .float(let double): return double
            default:
                typeMismatch(expected: [.int, .float], actual: value.type, path)
                return nil
        }
    }

    mutating func string(_ value: TOMLValue, _ path: ConfigKeyPath) -> String? {
        if case .string(let string) = value { return string }
        typeMismatch(expected: [.string], actual: value.type, path)
        return nil
    }

    mutating func array(_ value: TOMLValue, _ path: ConfigKeyPath) -> [TOMLValue]? {
        if case .array(let array) = value { return array }
        typeMismatch(expected: [.array], actual: value.type, path)
        return nil
    }

    /// Sorted entries of a table.
    mutating func table(_ value: TOMLValue, _ path: ConfigKeyPath) -> [(key: String, value: TOMLValue)]? {
        if case .table = value { return value.sortedEntries }
        typeMismatch(expected: [.table], actual: value.type, path)
        return nil
    }

    /// All elements must be strings; the first offending element fails the whole array.
    mutating func stringArray(_ value: TOMLValue, _ path: ConfigKeyPath) -> [String]? {
        guard let array = array(value, path) else { return nil }
        var result: [String] = []
        for (index, element) in array.enumerated() {
            guard let string = string(element, path + index) else { return nil }
            result.append(string)
        }
        return result
    }

    mutating func enumValue<E: RawRepresentable & CaseIterable>(_ value: TOMLValue, _ path: ConfigKeyPath, _: E.Type) -> E?
        where E.RawValue == String
    {
        guard let raw = string(value, path) else { return nil }
        if let parsed = E(rawValue: raw) { return parsed }
        let possibleValues = E.allCases.map(\.rawValue).joined(separator: "|")
        error(path, "Can't parse '\(raw)'.\nPossible values: (\(possibleValues))")
        return nil
    }

    /// A command script (`'focus left'`) or a list of them (`['layout floating', 'mode main']`).
    /// Blank scripts are dropped; the scripts themselves are validated by SilkCore.
    mutating func commandScripts(_ value: TOMLValue, _ path: ConfigKeyPath) -> CommandScripts {
        switch value {
            case .string(let script):
                return CommandScripts(isBlank(script) ? [] : [script])
            case .array(let elements):
                var scripts: [String] = []
                for (index, element) in elements.enumerated() {
                    if case .string(let script) = element {
                        if !isBlank(script) { scripts.append(script) }
                    } else {
                        typeMismatch(expected: [.string], actual: element.type, path + index)
                    }
                }
                return CommandScripts(scripts)
            default:
                typeMismatch(expected: [.string, .array], actual: value.type, path)
                return .empty
        }
    }

    /// Ensures `value` is a table and has exactly one key (`expectedKey`, when given), as in `{ monitor.main = 16 }`.
    /// On success `path` is extended with that key.
    mutating func singleKeyTable(_ value: TOMLValue, expectedKey: String?, _ path: inout ConfigKeyPath) -> (key: String, value: TOMLValue)? {
        guard let entries = table(value, path) else { return nil }
        guard entries.count == 1, expectedKey == nil || entries[0].key == expectedKey else {
            error(path, expectedKey.map { "The table is expected to have a single key '\($0)'" } ?? "The table is expected to have a single key")
            return nil
        }
        path = path + entries[0].key
        return entries[0]
    }
}

func isBlank(_ string: String) -> Bool {
    string.allSatisfy(\.isWhitespace)
}

/// Assigns `value` to `target` unless parsing failed.
func assign<T>(_ target: inout T, _ value: T?) {
    if let value { target = value }
}

// MARK: Top level

extension ConfigParser {
    static let latestConfigVersion = 2

    mutating func parseRoot(_ root: [String: TOMLValue]) -> Config {
        var config = Config()

        // Parsed first: they change how other keys are interpreted.
        if let raw = root["config-version"] {
            assign(&config.configVersion, parseConfigVersion(raw, .root + "config-version"))
        }
        if let raw = root["key-mapping"] {
            config.keyMapping = parseKeyMapping(raw, .root + "key-mapping")
        }
        let keyCodes = config.keyMapping.resolve()

        for (key, value) in TOMLValue.table(root).sortedEntries {
            let path = ConfigKeyPath.root + key
            switch key {
                case "config-version", "key-mapping": break

                case "after-startup-command": config.afterStartupCommand = commandScripts(value, path)
                case "after-login-command": parseDeprecatedAfterLoginCommand(value, path)
                case "on-focus-changed": config.onFocusChanged = commandScripts(value, path)
                case "on-mode-changed": config.onModeChanged = commandScripts(value, path)
                case "on-focused-monitor-changed": config.onFocusedMonitorChanged = commandScripts(value, path)

                case "enable-normalization-flatten-containers":
                    assign(&config.enableNormalizationFlattenContainers, bool(value, path))
                case "enable-normalization-opposite-orientation-for-nested-containers":
                    assign(&config.enableNormalizationOppositeOrientationForNestedContainers, bool(value, path))

                case "default-root-container-layout": assign(&config.defaultRootContainerLayout, parseLayout(value, path))
                case "default-root-container-orientation":
                    assign(&config.defaultRootContainerOrientation, parseOrientation(value, path))

                case "start-at-login": assign(&config.startAtLogin, bool(value, path))
                case "auto-reload-config": assign(&config.autoReloadConfig, bool(value, path))
                case "automatically-unhide-macos-hidden-apps": assign(&config.automaticallyUnhideMacosHiddenApps, bool(value, path))
                case "accordion-padding": assign(&config.accordionPadding, int(value, path))
                case "persistent-workspaces": assign(&config.persistentWorkspaces, parsePersistentWorkspaces(value, path))
                case "exec-on-workspace-change": assign(&config.execOnWorkspaceChange, stringArray(value, path))
                case "exec": config.exec = parseExec(value, path)
                case "focus-follows-mouse": assign(&config.focusFollowsMouse, parseFocusFollowsMouse(value, path))

                case "mode": config.modes = parseModes(value, path, keyCodes)
                case "gaps": config.gaps = parseGaps(value, path)
                case "workspace-to-monitor-force-assignment":
                    config.workspaceToMonitorForceAssignment = parseWorkspaceToMonitorForceAssignment(value, path)
                case "on-window-detected": config.onWindowDetected = parseOnWindowDetected(value, path)

                case "focus-backend": assign(&config.focusBackend, enumValue(value, path, FocusBackend.self))
                case "animations": config.animations = parseAnimations(value, path)
                case "borders": config.borders = parseBorders(value, path)

                case "non-empty-workspaces-root-containers-layout-on-startup":
                    if let raw = string(value, path), raw != "smart" {
                        error(path, "'non-empty-workspaces-root-containers-layout-on-startup' is deprecated. Please drop it from your config")
                    }
                case "indent-for-nested-containers-with-the-same-orientation":
                    error(path, "Deprecated. Please drop it from the config. See https://github.com/nikitabobko/AeroSpace/issues/96")

                default: unknownKey(path)
            }
        }

        if config.configVersion <= 1 {
            if root["persistent-workspaces"] != nil {
                error(.root + "persistent-workspaces", "This config option is only available since 'config-version = 2'")
            }
            config.persistentWorkspaces = Self.inferredPersistentWorkspaces(config)
        }

        if config.enableNormalizationFlattenContainers, Self.containsSplitCommand(config) {
            error(.root, """
                The config contains:
                1. usage of 'split' command
                2. enable-normalization-flatten-containers = true
                These two settings don't play nicely together. 'split' command has no effect when enable-normalization-flatten-containers is disabled.

                My recommendation: keep the normalizations enabled, and prefer 'join-with' over 'split'.
                """)
        }

        if config.configVersion < Self.latestConfigVersion {
            warning(.root, "The current 'config-version = \(config.configVersion)' is outdated. " +
                "Please consider migrating to 'config-version = \(Self.latestConfigVersion)'. " +
                "See https://nikitabobko.github.io/AeroSpace/guide#config-version for the migration guide.")
        }
        return config
    }

    private mutating func parseConfigVersion(_ value: TOMLValue, _ path: ConfigKeyPath) -> Int? {
        guard let version = int(value, path) else { return nil }
        guard (1 ... Self.latestConfigVersion).contains(version) else {
            error(path, "config-version must be in [1, \(Self.latestConfigVersion)] range")
            return nil
        }
        return version
    }

    private mutating func parseDeprecatedAfterLoginCommand(_ value: TOMLValue, _ path: ConfigKeyPath) {
        if case .array(let array) = value, array.isEmpty { return }
        error(path, "after-login-command is deprecated since AeroSpace 0.19.0. https://github.com/nikitabobko/AeroSpace/issues/1482")
    }

    private mutating func parseLayout(_ value: TOMLValue, _ path: ConfigKeyPath) -> ContainerLayout? {
        guard let raw = string(value, path) else { return nil }
        if let layout = ContainerLayout(rawValue: raw) { return layout }
        if raw == "list" { return .tiles } // Pre-0.10 name of 'tiles'
        error(path, "Can't parse layout '\(raw)'")
        return nil
    }

    private mutating func parseOrientation(_ value: TOMLValue, _ path: ConfigKeyPath) -> DefaultOrientation? {
        guard let raw = string(value, path) else { return nil }
        if let orientation = DefaultOrientation(rawValue: raw) { return orientation }
        error(path, "Can't parse default container orientation '\(raw)'")
        return nil
    }

    private mutating func parsePersistentWorkspaces(_ value: TOMLValue, _ path: ConfigKeyPath) -> [String]? {
        guard let names = stringArray(value, path) else { return nil }
        guard Set(names).count == names.count else {
            error(path, "Contains duplicated workspace names")
            return nil
        }
        return names
    }

    private mutating func parseFocusFollowsMouse(_ value: TOMLValue, _ path: ConfigKeyPath) -> Bool? {
        guard let entries = table(value, path) else { return nil }
        var enabled: Bool?
        for (key, value) in entries {
            switch key {
                case "enabled": enabled = bool(value, path + key)
                default: unknownKey(path + key)
            }
        }
        return enabled
    }

    /// `config-version = 1` semantics: every workspace named by a `workspace` / `move-node-to-workspace` binding,
    /// or by `workspace-to-monitor-force-assignment`, is persistent.
    private static func inferredPersistentWorkspaces(_ config: Config) -> [String] {
        let bindingScripts = config.modes.sorted { $0.key < $1.key }
            .flatMap { $0.value.bindings.sorted { $0.key < $1.key } }
            .flatMap(\.value.commands.scripts)
        let fromBindings = bindingScripts
            .flatMap(CommandScriptScanner.commands)
            .compactMap(CommandScriptScanner.workspaceName)
        var seen = Set<String>()
        return (fromBindings + config.workspaceToMonitorForceAssignment.keys.sorted()).filter { seen.insert($0).inserted }
    }

    private static func containsSplitCommand(_ config: Config) -> Bool {
        config.modes.values
            .flatMap(\.bindings.values)
            .flatMap(\.commands.scripts)
            .flatMap(CommandScriptScanner.commands)
            .contains { $0.first == "split" }
    }
}
