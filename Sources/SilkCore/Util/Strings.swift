import Foundation

extension String {
    var singleQuoted: String { "'" + self + "'" }
    var doubleQuoted: String { "\"" + self + "\"" }

    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }

    /// Prefixes every non-empty line (AeroSpace's `prependLines`: empty lines are dropped).
    func prependingLines(_ prefix: String) -> String {
        split(separator: "\n").map { prefix + $0 }.joined(separator: "\n")
    }

    /// Prefixes every line, keeping empty ones (AeroSpace's `prefixLines`).
    func prefixingLines(with prefix: String) -> String {
        split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(separator: "\n")
    }

    /// A CLI flag such as `--foo` or `-h`; `--` and `-` are not flags.
    var isCliDashFlag: Bool { self != "--" && self != "-" && hasPrefix("-") }
}

extension [String] {
    /// Formats parse errors the way AeroSpace prints them: `ERROR: ` on the first line of each error,
    /// continuation lines indented to align.
    func joinErrors() -> String {
        map { error in
            error.split(separator: "\n").enumerated()
                .map { index, line in index == 0 ? "ERROR: " + line : "       " + line }
                .joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    /// `(a|b|c)`
    var joinedCliArgs: String { "(" + joined(separator: "|") + ")" }

    /// Joins command arguments back into a shell-ish string, quoting where needed (AeroSpace `joinArgs`).
    func joinArgs() -> String {
        map { arg in
            let containsWhitespace = arg.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            let containsSingleQuote = arg.contains("'")
            let containsDoubleQuote = arg.contains("\"")
            switch true {
                case containsDoubleQuote && !containsSingleQuote: return arg.singleQuoted
                case containsSingleQuote && !containsDoubleQuote: return arg.doubleQuoted
                case containsSingleQuote && containsDoubleQuote:
                    return arg.replacingOccurrences(of: "'", with: "\\'")
                        .replacingOccurrences(of: "\"", with: "\\\"").doubleQuoted
                case containsWhitespace: return arg.singleQuoted
                default: return arg
            }
        }
        .joined(separator: " ")
    }

    /// Joins with `separator` but stops once `maxLength` characters are used, appending `trailing`
    /// (AeroSpace `joinTruncating`, used for the menu bar workspace list).
    func joinTruncating(separator: String, length maxLength: Int, trailing: String = "…") -> String {
        guard var result = first else { return "" }
        var remaining = maxLength
        for element in dropFirst() {
            let elementCount = separator.count + element.count
            if remaining < elementCount / 2 { return result + separator + trailing }
            let joined = separator + element
            if elementCount < remaining {
                result += joined
                remaining -= elementCount
            } else {
                return result + joined.prefix(remaining) + trailing
            }
        }
        return result
    }
}

extension CaseIterable where Self: RawRepresentable, RawValue == String {
    static var cliArgsCases: [String] { allCases.map(\.rawValue) }
    /// `(a|b|c)` built from the raw values.
    static var unionLiteral: String { cliArgsCases.joinedCliArgs }
}

/// Parses a raw-value enum with AeroSpace's error message.
func parseEnum<T: RawRepresentable & CaseIterable>(_ raw: String, _: T.Type) -> Result<T, ParseError> where T.RawValue == String {
    if let value = T(rawValue: raw) { return .success(value) }
    return .failure(ParseError("Can't parse '\(raw)'.\nPossible values: \(T.unionLiteral)"))
}

/// A user-facing error message (argument parsing, interpolation, workspace names…).
struct ParseError: Error, Equatable, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

extension Bool {
    /// Logical implication: `!self || other`.
    func implies(_ other: @autoclosure () -> Bool) -> Bool { !self || other() }
}

extension Array {
    func element(at index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
    func element(wrappingIndex index: Int) -> Element? {
        isEmpty ? nil : self[((index % count) + count) % count]
    }
}
