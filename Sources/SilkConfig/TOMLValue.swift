import Foundation
import TOMLDecoder

/// The untyped TOML document, as AeroSpace's `OrderedJson`. Tables are iterated in sorted key order so
/// diagnostics come out deterministic (TOMLDecoder's dictionaries are unordered).
indirect enum TOMLValue: Equatable {
    case table([String: TOMLValue])
    case array([TOMLValue])
    case string(String)
    case int(Int)
    case float(Double)
    case bool(Bool)

    var type: TOMLType {
        switch self {
            case .table: .table
            case .array: .array
            case .string: .string
            case .int: .int
            case .float: .float
            case .bool: .bool
        }
    }

    /// Sorted entries of a table value; empty for non-tables.
    var sortedEntries: [(key: String, value: TOMLValue)] {
        guard case .table(let table) = self else { return [] }
        return table.sorted { $0.key < $1.key }
    }

    /// Parses TOML source. Values of unsupported types (dates, times) are dropped with an error diagnostic.
    static func parse(_ source: String, diagnostics: inout [ConfigDiagnostic]) throws(TOMLError) -> [String: TOMLValue] {
        let dictionary: [String: Any] = try .init(TOMLTable(source: source))
        return convert(table: dictionary, .root, &diagnostics)
    }

    private static func convert(table: [String: Any], _ path: ConfigKeyPath, _ diagnostics: inout [ConfigDiagnostic]) -> [String: TOMLValue] {
        var result: [String: TOMLValue] = [:]
        for (key, value) in table.sorted(by: { $0.key < $1.key }) {
            result[key] = convert(value, path + key, &diagnostics)
        }
        return result
    }

    private static func convert(_ any: Any, _ path: ConfigKeyPath, _ diagnostics: inout [ConfigDiagnostic]) -> TOMLValue? {
        switch any {
            case let table as [String: Any]: return .table(convert(table: table, path, &diagnostics))
            case let array as [Any]:
                return .array(array.enumerated().compactMap { index, element in convert(element, path + index, &diagnostics) })
            case let string as String: return .string(string)
            case let bool as Bool: return .bool(bool)
            case let int as Int64: return .int(Int(int)) // Int is 64-bit on every supported platform
            case let double as Double: return .float(double)
            default:
                diagnostics.append(ConfigDiagnostic(.error, path.description, "Unsupported TOML type: \(Swift.type(of: any))"))
                return nil
        }
    }
}

enum TOMLType: String {
    case table = "Table", array = "Array", string = "String", int = "Int", float = "Float", bool = "Bool"
}

/// A location in the TOML document, rendered as AeroSpace backtraces: `mode.main.binding.alt-h`, `gaps.outer.top[1]`.
struct ConfigKeyPath: CustomStringConvertible {
    private enum Component {
        case key(String)
        case index(Int)
    }

    private var components: [Component] = []

    static let root = ConfigKeyPath()

    var isTopLevelKey: Bool {
        guard components.count == 1, case .key = components[0] else { return false }
        return true
    }

    var description: String {
        var result = ""
        for component in components {
            switch component {
                case .key(let key): result += result.isEmpty ? key : ".\(key)"
                case .index(let index): result += "[\(index)]"
            }
        }
        return result
    }

    static func + (path: ConfigKeyPath, key: String) -> ConfigKeyPath {
        var path = path
        path.components.append(.key(key))
        return path
    }

    static func + (path: ConfigKeyPath, index: Int) -> ConfigKeyPath {
        var path = path
        path.components.append(.index(index))
        return path
    }
}
