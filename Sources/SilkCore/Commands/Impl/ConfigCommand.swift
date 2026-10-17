import Foundation

struct ConfigCommand: ParsableCommand {
    static let kind = CommandKind.config
    static let help = HelpText.config
    static let parser = ArgParser<Self>(
        flags: [
            "--json": .trueBool(\.json),
            "--keys": .trueBool(\.keys),
            "--major-keys": .trueBool(\.majorKeys),
            "--all-keys": .trueBool(\.allKeys),
            "--config-path": .trueBool(\.configPath),
            "--get": .single(\.keyNameToGet, "<name>") { .success($0) },
        ],
        positional: []
    )

    var common: CommonArgs
    var json = false
    var majorKeys = false
    var keys = false
    var allKeys = false
    var configPath = false
    var keyNameToGet: String?
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    static func parse(_ args: [String]) -> ParsedCmd<ConfigCommand> {
        parseArgs(args)
            .flatMap { raw in
                var modes: [String] = []
                if raw.keyNameToGet != nil { modes.append("--get") }
                if raw.majorKeys { modes.append("--major-keys") }
                if raw.allKeys { modes.append("--all-keys") }
                if raw.configPath { modes.append("--config-path") }
                return switch modes.count {
                    case 1: .cmd(raw)
                    case 0: .failure("Mandatory flag is not specified (--get|--major-keys|--all-keys|--config-path)")
                    default: .failure("Conflicting flags are specified: \(modes.joined(separator: ", "))")
                }
            }
            .filter("--keys flag requires --get flag") { !$0.keys || $0.keyNameToGet != nil }
            .filter("--json flag requires --get flag") { !$0.json || $0.keyNameToGet != nil }
    }

    func run(_ context: CommandContext) -> Int32 {
        let io = context.io
        let world = context.world
        if let key = keyNameToGet {
            return getKey(key, context)
        }
        if majorKeys {
            let modeKeys = world.config.modes.keys.sorted().map { "mode.\($0).binding" }
            io.out(([".", "mode"] + modeKeys).joined(separator: "\n"))
            return ExitCode.success
        }
        if allKeys {
            var allKeys: [String] = []
            ConfigMapValue.build(world).dumpAllKeys(path: ".", into: &allKeys)
            io.out(allKeys.joined(separator: "\n"))
            return ExitCode.success
        }
        io.out(world.configURL?.absoluteURL.path ?? "")
        return ExitCode.success
    }

    private func getKey(_ key: String, _ context: CommandContext) -> Int32 {
        let io = context.io
        let keyPath: [String]
        switch key {
            case ".": keyPath = []
            case "": return io.fail("Invalid empty key")
            case _ where key.contains("..") || key.hasSuffix("."): return io.fail("Invalid key '\(key)'")
            default: keyPath = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        }
        var value: ConfigMapValue
        switch ConfigMapValue.build(context.world).find(keyPath[...]) {
            case .success(let found): value = found
            case .failure(let error): return io.fail(error.message)
        }
        if keys {
            switch value {
                case .scalar(let scalar): return io.fail("--keys flag cannot be applied to scalar object '\(scalar)'")
                case .map(let map): value = .array(map.keys.sorted().map { .scalar(.string($0)) })
                case .array(let array): value = .array(array.indices.map { .scalar(.int($0)) })
            }
        }
        if json {
            guard let encoded = JSONEncoder.aeroSpace.encodeToString(value) else { return io.fail("Can't convert json Data to String") }
            io.out(encoded)
            return ExitCode.success
        }
        switch value {
            case .scalar(let scalar):
                io.out(scalar.describe)
                return ExitCode.success
            case .map:
                return io.fail("Complicated objects can be printed only with --json flag. Alternatively, you can try to inspect keys of the object with --keys flag")
            case .array(let array):
                var lines: [String] = []
                for element in array {
                    guard case .scalar(let scalar) = element else {
                        return io.fail("Printing array of non-string objects is supported only with --json flag." +
                            "Alternatively, you can try to inspect keys of the object with --keys flag")
                    }
                    lines.append(scalar.describe)
                }
                io.out(lines.sorted().joined(separator: "\n"))
                return ExitCode.success
        }
    }
}

/// The part of the config exposed to `config --get`: `mode.<name>.binding.<key>` → command description.
enum ConfigMapValue: Encodable {
    /// Deliberately not `CustomStringConvertible`: AeroSpace's `--keys` error prints the raw enum case.
    enum Scalar: Encodable {
        case string(String)
        case int(Int)

        var describe: String {
            switch self {
                case .string(let string): string
                case .int(let int): String(int)
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
                case .string(let string): try container.encode(string)
                case .int(let int): try container.encode(int)
            }
        }
    }

    case scalar(Scalar)
    case map([String: ConfigMapValue])
    case array([ConfigMapValue])

    static func build(_ world: World) -> ConfigMapValue {
        var modes: [String: ConfigMapValue] = [:]
        for (modeName, bindings) in world.compiledConfig.bindings {
            var descriptions: [String: ConfigMapValue] = [:]
            for (descriptor, shell) in bindings {
                descriptions[descriptor] = .scalar(.string(shell.description { $0.description }))
            }
            modes[modeName] = .map(["binding": .map(descriptions)])
        }
        return .map(["mode": .map(modes)])
    }

    func find(_ keyPath: ArraySlice<String>) -> Result<ConfigMapValue, ParseError> {
        guard let key = keyPath.first else { return .success(self) }
        switch self {
            case .scalar(let scalar):
                return .failure(ParseError("Can't dereference scalar value '\(scalar.describe)'"))
            case .map(let map):
                guard let child = map[key] else { return .failure(ParseError("No value at key token '\(key)'")) }
                return child.find(keyPath.dropFirst())
            case .array(let array):
                guard let index = Int(key) else { return .failure(ParseError("Can't convert key token '\(key)' to Int")) }
                guard let child = array.element(at: index) else {
                    return .failure(ParseError("Index out of bounds. Index: \(index), Size: \(array.count)"))
                }
                return child.find(keyPath.dropFirst())
        }
    }

    func dumpAllKeys(path: String, into result: inout [String]) {
        result.append(path)
        switch self {
            case .scalar:
                break
            case .map(let map):
                for (key, value) in map.sorted(by: { $0.key < $1.key }) {
                    value.dumpAllKeys(path: path == "." ? key : path + "." + key, into: &result)
                }
            case .array(let array):
                for (index, value) in array.enumerated() {
                    value.dumpAllKeys(path: path == "." ? String(index) : path + "." + String(index), into: &result)
                }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
            case .scalar(let scalar): try container.encode(scalar)
            case .map(let map): try container.encode(map)
            case .array(let array): try container.encode(array)
        }
    }
}
