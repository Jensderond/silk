/// A piece of a `%{var}` interpolated string.
enum InterToken<T: Equatable>: Equatable {
    case literal(String)
    case interVar(T)
}

extension String {
    /// Splits `"id: %{window-id}"` into literals and variable names (AeroSpace `rawInterpolationTokens`).
    func rawInterpolationTokens(interpolationChar: Character) -> Result<[InterToken<String>], ParseError> {
        enum State {
            case literal(String)
            case sawInterpolationChar(previousLiteral: String)
            case variable(String)
        }
        var state = State.literal("")
        var result: [InterToken<String>] = []
        for char in Array(self).map(Optional.some) + [nil] {
            switch (state, char) {
                case (.literal(let literal), interpolationChar):
                    state = .sawInterpolationChar(previousLiteral: literal)
                case (.literal(let literal), let char?):
                    state = .literal(literal + String(char))
                case (.literal(let literal), nil):
                    result.append(.literal(literal))
                case (.sawInterpolationChar(let literal), "{"):
                    state = .variable("")
                    result.append(.literal(literal))
                case (.sawInterpolationChar(let literal), interpolationChar):
                    state = .sawInterpolationChar(previousLiteral: literal + String(interpolationChar))
                case (.sawInterpolationChar(let literal), let char?):
                    state = .literal(literal + String(interpolationChar) + String(char))
                case (.sawInterpolationChar(let literal), nil):
                    result.append(.literal(literal + String(interpolationChar)))
                case (.variable(let name), "}"):
                    result.append(.interVar(name))
                    state = .literal("")
                case (.variable(let name), "{"):
                    return .failure(ParseError("Can't parse '\(name + "{")' inside interpolation (Open curly brace is invalid character)"))
                case (.variable(let name), interpolationChar):
                    return .failure(ParseError("Can't parse '\(name + String(interpolationChar))' inside interpolation ('\(interpolationChar)' is disallowed character)"))
                case (.variable(let name), let char?):
                    state = .variable(name + String(char))
                case (.variable, nil):
                    return .failure(ParseError("Unbalanced curly braces"))
            }
        }
        return .success(result.filter { $0 != .literal("") })
    }

    /// Like `rawInterpolationTokens`, with variable names parsed as `T`.
    func interpolationTokens<T: RawRepresentable & CaseIterable & Equatable>(
        interpolationChar: Character,
        of _: T.Type
    ) -> Result<[InterToken<T>], ParseError> where T.RawValue == String {
        rawInterpolationTokens(interpolationChar: interpolationChar).flatMap { rawTokens in
            var result: [InterToken<T>] = []
            for token in rawTokens {
                switch token {
                    case .literal(let literal):
                        result.append(.literal(literal))
                    case .interVar(let name):
                        switch parseEnum(name, T.self) {
                            case .success(let variable): result.append(.interVar(variable))
                            case .failure(let error): return .failure(error)
                        }
                }
            }
            return .success(result)
        }
    }
}
