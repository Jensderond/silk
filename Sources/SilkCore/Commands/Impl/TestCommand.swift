struct TestCommand: ParsableCommand {
    enum InfixOperator: String, CaseIterable {
        case equals = "="
        case matchesRegex = "~="
    }

    static let kind = CommandKind.test
    static let help = HelpText.test
    static let parser = ArgParser<Self>(
        flags: [:],
        positional: [
            .mandatory(\.lhs, placeholder: "<lhs>") { input in
                let result = input.arg.interpolationTokens(interpolationChar: "%", of: FormatVar.self).flatMap { tokens -> Result<FormatVar?, ParseError> in
                    if tokens.count == 1, case .interVar(let variable) = tokens[0] { return .success(variable) }
                    return .failure(ParseError("Left hand side must be a single interpolation variable"))
                }
                return ParsedArg(value: result, advanceBy: 1)
            },
            .mandatory(\.infixOperator, placeholder: "<operator>", parseEnumArg(InfixOperator.self)),
            .mandatory(\.rhs, placeholder: "<rhs>") { input in
                let result = input.arg.rawInterpolationTokens(interpolationChar: "%").flatMap { tokens -> Result<String, ParseError> in
                    if tokens.count == 1, case .literal(let literal) = tokens[0] { return .success(literal) }
                    return .failure(ParseError("Right hand side doesn't allow interpolation variables"))
                }
                return ParsedArg(value: result, advanceBy: 1)
            },
        ]
    )

    var common: CommonArgs
    var lhs: FormatVar?
    var infixOperator = InfixOperator.equals
    var rhs = ""
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    func run(_ context: CommandContext) -> Int32 {
        let io = context.io
        guard let lhs else { return io.fail(internalErrorMessage()) }
        guard let target = context.resolveTarget(common) else { return ExitCode.fail }
        let object: AeroObj = target.window.map { .window($0, title: $0.title) } ?? .workspace(target.workspace)
        let value: Primitive
        switch Formatter(world: context.world).expand(lhs, object) {
            case .success(let expanded):
                value = expanded
            case .failure(let error):
                if case .unknownInterpolationVariable = error { return io.fail(noWindowIsFocused) }
                return io.fail(error.description)
        }
        let lhsType = value.kind.rawValue
        let incompatibleMessage = "Interpolation variable: \(lhs.rawValue.singleQuoted) has a type of \(lhsType). The \(lhsType) type is not compatible with \(infixOperator.rawValue.singleQuoted) operator."
        let result: Result<Bool, ParseError>
        switch (value, infixOperator) {
            case (.bool(let lhsValue), .equals):
                result = Bool(rhs).map { .success($0 == lhsValue) } ?? .failure(ParseError("Can't convert String \(rhs.singleQuoted) to Bool"))
            case (.int(let lhsValue), .equals):
                result = Int64(rhs).map { .success($0 == lhsValue) } ?? .failure(ParseError("Can't convert String \(rhs.singleQuoted) to Int"))
            case (.bool, .matchesRegex), (.int, .matchesRegex):
                result = .failure(ParseError(incompatibleMessage))
            case (.string(let lhsValue), .equals):
                result = .success(lhsValue == rhs)
            case (.string(let lhsValue), .matchesRegex):
                do throws(ParseError) {
                    result = .success(try CaseInsensitiveRegex(rhs).matches(lhsValue))
                } catch {
                    result = .failure(error)
                }
        }
        switch result {
            case .success(let matches): return matches ? ExitCode.success : ExitCode.conditionalFalse
            case .failure(let error): return io.fail(error.message)
        }
    }
}

struct TestNotCommand: ParsableCommand {
    static let kind = CommandKind.testNot
    static let help = HelpText.testNot
    static let parser = ArgParser<Self>(flags: [:], positional: [])

    var common: CommonArgs
    var test: TestCommand
    init(rawArgs: [String]) {
        common = CommonArgs(rawArgs: rawArgs)
        test = TestCommand(rawArgs: rawArgs)
    }

    static func parse(_ args: [String]) -> ParsedCmd<TestNotCommand> {
        TestCommand.parse(args).map { test in
            var command = TestNotCommand(rawArgs: args)
            command.test = test
            return command
        }
    }

    func run(_ context: CommandContext) -> Int32 {
        switch test.run(context) {
            case ExitCode.success: ExitCode.conditionalFalse
            case ExitCode.conditionalFalse: ExitCode.success
            default: ExitCode.fail
        }
    }
}
