import Foundation

// AeroSpace sections: key-mapping, mode, gaps, monitor patterns, on-window-detected, exec.

extension ConfigParser {
    // MARK: key-mapping

    mutating func parseKeyMapping(_ value: TOMLValue, _ path: ConfigKeyPath) -> KeyMapping {
        var mapping = KeyMapping()
        guard let entries = table(value, path) else { return mapping }
        for (key, value) in entries {
            let path = path + key
            switch key {
                case "preset": assign(&mapping.preset, enumValue(value, path, KeyMappingPreset.self))
                case "key-notation-to-key-code": mapping.overrides = parseKeyNotationToKeyCode(value, path)
                default: unknownKey(path)
            }
        }
        return mapping
    }

    private mutating func parseKeyNotationToKeyCode(_ value: TOMLValue, _ path: ConfigKeyPath) -> [String: UInt32] {
        guard let entries = table(value, path) else { return [:] }
        var result: [String: UInt32] = [:]
        for (notation, value) in entries {
            guard KeyNotation.isValidNotation(notation) else {
                error(path, "'\(notation)' is invalid key notation")
                continue
            }
            let path = path + notation
            guard let keyName = string(value, path) else { continue }
            if let keyCode = KeyNotation.qwerty[keyName] {
                result[notation] = keyCode
            } else {
                error(path, "'\(keyName)' is invalid key code")
            }
        }
        return result
    }

    // MARK: mode

    mutating func parseModes(_ value: TOMLValue, _ path: ConfigKeyPath, _ keyCodes: [String: UInt32]) -> [String: Mode] {
        guard let entries = table(value, path) else { return Config().modes }
        var modes: [String: Mode] = [:]
        for (name, value) in entries {
            modes[name] = parseMode(name, value, path + name, keyCodes)
        }
        if modes[mainModeName] == nil {
            error(path, "Please specify '\(mainModeName)' mode")
            modes[mainModeName] = Mode(name: mainModeName)
        }
        return modes
    }

    private mutating func parseMode(_ name: String, _ value: TOMLValue, _ path: ConfigKeyPath, _ keyCodes: [String: UInt32]) -> Mode {
        var mode = Mode(name: name)
        guard let entries = table(value, path) else { return mode }
        for (key, value) in entries {
            switch key {
                case "binding": mode.bindings = parseBindings(value, path + key, keyCodes)
                default: unknownKey(path + key)
            }
        }
        return mode
    }

    private mutating func parseBindings(_ value: TOMLValue, _ path: ConfigKeyPath, _ keyCodes: [String: UInt32]) -> [String: Binding] {
        guard let entries = table(value, path) else { return [:] }
        var bindings: [String: Binding] = [:]
        var descriptorByNormalized: [String: String] = [:]
        for (descriptor, value) in entries {
            let path = path + descriptor
            switch KeyNotation.parseChord(descriptor, keyCodes: keyCodes) {
                case .failure(let failure):
                    error(path, failure.description)
                case .success(let chord):
                    let normalized = chord.normalizedDescriptor
                    if let previous = descriptorByNormalized[normalized] {
                        error(path, "'\(normalized)' Binding redeclaration")
                        bindings[previous] = nil
                    }
                    descriptorByNormalized[normalized] = descriptor
                    bindings[descriptor] = Binding(descriptor: descriptor, chord: chord, commands: commandScripts(value, path))
            }
        }
        return bindings
    }

    // MARK: gaps

    mutating func parseGaps(_ value: TOMLValue, _ path: ConfigKeyPath) -> Gaps {
        var gaps = Gaps()
        guard let entries = table(value, path) else { return gaps }
        for (key, value) in entries {
            let path = path + key
            switch key {
                case "inner":
                    guard let entries = table(value, path) else { continue }
                    for (key, value) in entries {
                        let path = path + key
                        switch key {
                            case "horizontal": gaps.inner.horizontal = dynamicInt(value, path)
                            case "vertical": gaps.inner.vertical = dynamicInt(value, path)
                            default: unknownKey(path)
                        }
                    }
                case "outer":
                    guard let entries = table(value, path) else { continue }
                    for (key, value) in entries {
                        let path = path + key
                        switch key {
                            case "left": gaps.outer.left = dynamicInt(value, path)
                            case "right": gaps.outer.right = dynamicInt(value, path)
                            case "top": gaps.outer.top = dynamicInt(value, path)
                            case "bottom": gaps.outer.bottom = dynamicInt(value, path)
                            default: unknownKey(path)
                        }
                    }
                default: unknownKey(path)
            }
        }
        return gaps
    }

    /// `8` or `[{ monitor.main = 16 }, { monitor."dell" = 32 }, 24]` (the last element is the fallback).
    private mutating func dynamicInt(_ value: TOMLValue, _ path: ConfigKeyPath) -> DynamicValue<Int> {
        switch value {
            case .int(let int):
                return .constant(int)
            case .array(let array):
                guard !array.isEmpty else {
                    error(path, "The array must not be empty")
                    return .constant(0)
                }
                guard case .int(let fallback) = array.last else {
                    error(path, "The last item in the array must be of type Int")
                    return .constant(0)
                }
                guard array.count > 1 else {
                    error(path, "The array must contain at least one monitor pattern")
                    return .constant(0)
                }
                let rules = array.dropLast().enumerated().compactMap { index, element in
                    perMonitorInt(element, path + index)
                }
                return .perMonitor(rules, default: fallback)
            default:
                error(path, "Unsupported type: \(value.type.rawValue), expected: Int or array")
                return .constant(0)
        }
    }

    private mutating func perMonitorInt(_ value: TOMLValue, _ path: ConfigKeyPath) -> PerMonitorValue<Int>? {
        var path = path
        guard let (_, monitorTable) = singleKeyTable(value, expectedKey: "monitor", &path),
              let (rawPattern, rawValue) = singleKeyTable(monitorTable, expectedKey: nil, &path)
        else { return nil }
        let pattern: MonitorPattern
        switch Self.monitorPattern(rawPattern) {
            case .success(let parsed): pattern = parsed
            case .failure(let failure):
                error(path, failure.message)
                return nil
        }
        guard case .int(let int) = rawValue else {
            typeMismatch(expected: [.int], actual: rawValue.type, path)
            return nil
        }
        return PerMonitorValue(monitor: pattern, value: int)
    }

    // MARK: Monitor patterns

    struct PatternError: Error {
        let message: String
    }

    /// `main`, `secondary`, a 1-based sequence number, or a case-insensitive regex (AeroSpace's parseMonitorDescription).
    static func monitorPattern(_ raw: String) -> Result<MonitorPattern, PatternError> {
        if let number = Int(raw) {
            return number >= 1
                ? .success(.sequenceNumber(number))
                : .failure(PatternError(message: "Monitor sequence numbers uses 1-based indexing. Values less than 1 are illegal"))
        }
        switch raw {
            case "main": return .success(.main)
            case "secondary": return .success(.secondary)
            case "": return .failure(PatternError(message: "Empty string is an illegal monitor description"))
            default: return validateRegex(raw).map { _ in .nameRegex(raw) }
        }
    }

    static func validateRegex(_ raw: String) -> Result<Void, PatternError> {
        do {
            _ = try Regex(raw)
            return .success(())
        } catch {
            return .failure(PatternError(message: "Can't parse '\(raw)' regex: \(error.localizedDescription)"))
        }
    }

    private mutating func monitorPattern(_ value: TOMLValue, _ path: ConfigKeyPath) -> MonitorPattern? {
        let raw: String
        switch value {
            case .string(let string): raw = string
            case .int(let int): raw = String(int)
            default:
                typeMismatch(expected: [.string, .int], actual: value.type, path)
                return nil
        }
        switch Self.monitorPattern(raw) {
            case .success(let pattern): return pattern
            case .failure(let failure):
                error(path, failure.message)
                return nil
        }
    }

    mutating func parseWorkspaceToMonitorForceAssignment(_ value: TOMLValue, _ path: ConfigKeyPath) -> [String: [MonitorPattern]] {
        guard let entries = table(value, path) else { return [:] }
        var result: [String: [MonitorPattern]] = [:]
        for (workspace, value) in entries {
            let path = path + workspace
            if case .array(let array) = value {
                result[workspace] = array.enumerated().compactMap { index, element in monitorPattern(element, path + index) }
            } else {
                result[workspace] = monitorPattern(value, path).map { [$0] } ?? []
            }
        }
        return result
    }

    // MARK: on-window-detected

    mutating func parseOnWindowDetected(_ value: TOMLValue, _ path: ConfigKeyPath) -> [WindowDetectedRule] {
        guard let array = array(value, path) else { return [] }
        return array.enumerated().compactMap { index, element in parseWindowDetectedRule(element, path + index) }
    }

    /// A rule with any error is dropped entirely (AeroSpace behavior): half-applied window rules are worse than none.
    private mutating func parseWindowDetectedRule(_ value: TOMLValue, _ path: ConfigKeyPath) -> WindowDetectedRule? {
        var ruleParser = ConfigParser()
        defer { absorb(ruleParser) }
        guard let entries = ruleParser.table(value, path) else { return nil }

        var rule = WindowDetectedRule()
        var hasCondition = false
        var hasRun = false
        for (key, value) in entries {
            let path = path + key
            switch key {
                case "if":
                    switch value {
                        case .table:
                            rule.matcher = ruleParser.parseWindowDetectedMatcher(value, path)
                            hasCondition = true
                        case .string(let script):
                            if !isBlank(script) {
                                rule.ifCommand = script
                                hasCondition = true
                            }
                        default:
                            // The legacy table form is intentionally not advertised.
                            ruleParser.typeMismatch(expected: [.string], actual: value.type, path)
                    }
                case "check-further-callbacks": assign(&rule.checkFurtherCallbacks, ruleParser.bool(value, path))
                case "run":
                    rule.run = ruleParser.commandScripts(value, path)
                    hasRun = true
                default: ruleParser.unknownKey(path)
            }
        }
        if !hasCondition, !rule.checkFurtherCallbacks {
            ruleParser.error(path, "Omitting 'if' is error prone. You can use `if = 'true'` to preserve the previous behavior.\n" +
                "But heads up! You may have missed 'check-further-callbacks = true'")
        }
        if !hasRun {
            ruleParser.error(path, "'run' is mandatory key")
        }
        return ruleParser.hasErrors ? nil : rule
    }

    private mutating func parseWindowDetectedMatcher(_ value: TOMLValue, _ path: ConfigKeyPath) -> WindowDetectedMatcher {
        var matcher = WindowDetectedMatcher()
        for (key, value) in value.sortedEntries {
            let path = path + key
            switch key {
                case "app-id": matcher.appId = string(value, path)
                case "workspace": matcher.workspace = string(value, path)
                case "app-name-regex-substring": matcher.appNameRegexSubstring = regex(value, path)
                case "window-title-regex-substring": matcher.windowTitleRegexSubstring = regex(value, path)
                case "during-aerospace-startup": matcher.duringStartup = bool(value, path)
                default: unknownKey(path)
            }
        }
        return matcher
    }

    private mutating func regex(_ value: TOMLValue, _ path: ConfigKeyPath) -> String? {
        guard let raw = string(value, path) else { return nil }
        if case .failure(let failure) = Self.validateRegex(raw) {
            error(path, failure.message)
            return nil
        }
        return raw
    }

    // MARK: exec

    mutating func parseExec(_ value: TOMLValue, _ path: ConfigKeyPath) -> ExecConfig {
        var exec = ExecConfig()
        guard let entries = table(value, path) else { return exec }
        for (key, value) in entries {
            let path = path + key
            switch key {
                case "inherit-env-vars": assign(&exec.inheritEnvVars, bool(value, path))
                case "env-vars": exec.env = parseEnvVars(value, path)
                default: unknownKey(path)
            }
        }
        return exec
    }

    private mutating func parseEnvVars(_ value: TOMLValue, _ path: ConfigKeyPath) -> [String: String] {
        guard let entries = table(value, path) else { return [:] }
        let overridden = Set(entries.map(\.key))
        var result: [String: String] = [:]
        for (name, value) in entries {
            let path = path + name
            if name == "PWD" { error(path, "Changing 'PWD' is not allowed") }
            guard let raw = string(value, path) else { continue }
            switch EnvInterpolation.tokens(raw) {
                case .failure(let failure):
                    error(path, failure.message)
                case .success(let tokens):
                    // A variable may reference its own inherited value, but not another overridden one.
                    let unavailable = tokens.compactMap(\.variableName).filter { $0 != name && overridden.contains($0) }
                    for variable in unavailable {
                        error(path, "Env variable '\(variable)' isn't presented in Silk env vars, " +
                            "or not available for interpolation (because it's mutated)")
                    }
                    if unavailable.isEmpty { result[name] = raw }
            }
        }
        return result
    }
}

let mainModeName = "main"
