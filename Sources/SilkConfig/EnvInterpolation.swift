import Foundation

/// `${VAR}` interpolation in `[exec.env-vars]`, with AeroSpace's syntax rules: a lone `$` or `$VAR` is literal,
/// `${` must be closed and the name may not contain `{` or `$`.
enum EnvInterpolation {
    enum Token: Equatable {
        case literal(String)
        case variable(String)

        var variableName: String? {
            if case .variable(let name) = self { name } else { nil }
        }
    }

    struct SyntaxError: Error {
        let message: String
    }

    static func tokens(_ string: String) -> Result<[Token], SyntaxError> {
        var tokens: [Token] = []
        var literal = ""
        var variable: String?
        var sawDollar = false
        for char in string {
            if var name = variable {
                switch char {
                    case "}":
                        tokens.append(.variable(name))
                        variable = nil
                    case "{", "$":
                        let reason = char == "{" ? "Open curly brace is invalid character" : "'$' is disallowed character"
                        return .failure(SyntaxError(message: "Can't parse '\(name)\(char)' inside interpolation (\(reason))"))
                    default:
                        name.append(char)
                        variable = name
                }
            } else if sawDollar {
                switch char {
                    case "{":
                        if !literal.isEmpty { tokens.append(.literal(literal)) }
                        literal = ""
                        variable = ""
                        sawDollar = false
                    case "$":
                        literal += "$" // the second '$' may still start an interpolation
                    default:
                        literal += "$\(char)"
                        sawDollar = false
                }
            } else if char == "$" {
                sawDollar = true
            } else {
                literal.append(char)
            }
        }
        if variable != nil { return .failure(SyntaxError(message: "Unbalanced curly braces")) }
        if sawDollar { literal += "$" }
        if !literal.isEmpty { tokens.append(.literal(literal)) }
        return .success(tokens)
    }
}

extension ExecConfig {
    /// The environment for `exec-*` commands and callbacks. Overrides are expanded against the process environment;
    /// an override may reference its own inherited value (`PATH = '/opt/bin:${PATH}'`). Unknown variables expand to "".
    public func environment(processEnvironment: [String: String]) -> [String: String] {
        var result = inheritEnvVars ? processEnvironment : [:]
        for (name, raw) in env {
            guard case .success(let tokens) = EnvInterpolation.tokens(raw) else { continue }
            result[name] = tokens.map { token in
                switch token {
                    case .literal(let literal): literal
                    case .variable(let variable): processEnvironment[variable] ?? ""
                }
            }.joined()
        }
        return result
    }
}
