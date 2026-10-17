/// The value parsed from one or more CLI arguments and how many arguments it consumed.
struct ParsedArg<Value> {
    var value: Result<Value, ParseError>
    var advanceBy: Int

    static func success(_ value: Value, advanceBy: Int) -> ParsedArg { ParsedArg(value: .success(value), advanceBy: advanceBy) }
    static func failure(_ message: String, advanceBy: Int) -> ParsedArg { ParsedArg(value: .failure(ParseError(message)), advanceBy: advanceBy) }
}

/// Input of a flag's value parser: the arguments after the flag itself.
struct FlagInput {
    let flag: String
    let index: Int
    let args: [String]

    var argOrNil: String? { args.element(at: index) }
    var nonFlagArgOrNil: String? { argOrNil.flatMap { $0.isCliDashFlag ? nil : $0 } }
    var nonFlagArgs: [String] { Array(args[index...].prefix { !$0.isCliDashFlag }) }
}

/// Input of a positional argument parser.
struct PositionalInput {
    let index: Int
    let args: [String]
    let sawDashDash: Bool

    var arg: String { args[index] }
    func arg(relative offset: Int) -> String? { args.element(at: index + offset) }
    var nonFlagArgs: [String] { Array(args[index...].prefix { !$0.isCliDashFlag }) }
}

/// Parses a flag's value(s) into `Root`.
struct FlagParser<Root> {
    let parse: (FlagInput, inout Root) -> (error: String?, advanceBy: Int)

    static func value<V>(_ keyPath: WritableKeyPath<Root, V>, _ parse: @escaping (FlagInput) -> ParsedArg<V>) -> FlagParser {
        FlagParser { input, root in
            let parsed = parse(input)
            switch parsed.value {
                case .success(let value):
                    root[keyPath: keyPath] = value
                    return (nil, parsed.advanceBy)
                case .failure(let error):
                    return (error.message, parsed.advanceBy)
            }
        }
    }

    static func constant<V>(_ keyPath: WritableKeyPath<Root, V>, _ value: V) -> FlagParser {
        .value(keyPath) { _ in .success(value, advanceBy: 0) }
    }

    static func trueBool(_ keyPath: WritableKeyPath<Root, Bool>) -> FlagParser { .constant(keyPath, true) }
    static func falseBool(_ keyPath: WritableKeyPath<Root, Bool>) -> FlagParser { .constant(keyPath, false) }

    /// `--flag [no]`
    static func optionalBool(_ keyPath: WritableKeyPath<Root, Bool?>) -> FlagParser {
        .value(keyPath) { input in input.argOrNil == "no" ? .success(false, advanceBy: 1) : .success(true, advanceBy: 0) }
    }

    /// `--flag <placeholder>`
    static func single<V>(
        _ keyPath: WritableKeyPath<Root, V?>,
        _ placeholder: String,
        _ mapper: @escaping (String) -> Result<V, ParseError>
    ) -> FlagParser {
        .value(keyPath) { input in
            guard let arg = input.nonFlagArgOrNil else {
                return .failure("'\(input.flag)' must be followed by '\(placeholder)'", advanceBy: 0)
            }
            switch mapper(arg) {
                case .success(let value): return .success(value, advanceBy: 1)
                case .failure(let error): return .failure("Failed to parse '\(arg)' CLI argument: \(error)", advanceBy: 1)
            }
        }
    }
}

/// Parses one positional argument (possibly consuming several CLI arguments) into `Root`.
struct PositionalParser<Root> {
    /// Reported as "Argument '<placeholder>' is mandatory" when the argument is missing.
    let mandatoryPlaceholder: String?
    let parse: (PositionalInput, inout Root) -> (error: String?, advanceBy: Int)

    static func value<V>(
        _ keyPath: WritableKeyPath<Root, V>,
        mandatoryPlaceholder: String? = nil,
        _ parse: @escaping (PositionalInput) -> ParsedArg<V>
    ) -> PositionalParser {
        PositionalParser(mandatoryPlaceholder: mandatoryPlaceholder) { input, root in
            let parsed = parse(input)
            switch parsed.value {
                case .success(let value):
                    root[keyPath: keyPath] = value
                    return (nil, parsed.advanceBy)
                case .failure(let error):
                    return (error.message, parsed.advanceBy)
            }
        }
    }

    static func mandatory<V>(
        _ keyPath: WritableKeyPath<Root, V>,
        placeholder: String,
        _ parse: @escaping (PositionalInput) -> ParsedArg<V>
    ) -> PositionalParser {
        .value(keyPath, mandatoryPlaceholder: placeholder, parse)
    }

    /// The `--` separator.
    static func dashDash(mandatory: Bool) -> PositionalParser {
        PositionalParser(mandatoryPlaceholder: mandatory ? "--" : nil) { input, _ in
            switch (input.arg, mandatory) {
                case ("--", _): (nil, 1)
                case (_, false): (nil, 0)
                case (_, true): ("Expected: --. Got: \(input.arg.singleQuoted)", 0)
            }
        }
    }
}

/// A command's argument grammar.
struct ArgParser<Root> {
    var flags: [String: FlagParser<Root>]
    var positional: [PositionalParser<Root>]
    var conflictingOptions: [Set<String>] = []
}

extension ArgParser {
    /// AeroSpace `parseSpecificCmdArgs`: flags in any order, positional arguments in order, `--` ends flags.
    func parse(_ initial: Root, _ args: [String], help: String, isNegativeNumberAllowed: Bool = false) -> ParsedCmd<Root> {
        var root = initial
        var errors: [String] = []
        var positionalIndex = 0
        var seenOptions: Set<String> = []
        var index = 0
        var positionalOnly = false

        loop: while index < args.count {
            let arg = args[index]
            if !positionalOnly && (arg == "-h" || arg == "--help") {
                return .help(help)
            }
            if !positionalOnly && arg.isCliDashFlag && !(isNegativeNumberAllowed && arg.isNegativeNumberLike) {
                guard let flagParser = flags[arg] else {
                    errors.append("Unknown flag \(arg.singleQuoted)")
                    break loop
                }
                index += 1
                if !seenOptions.insert(arg).inserted {
                    errors.append("Duplicated option \(arg.singleQuoted)")
                }
                let step = flagParser.parse(FlagInput(flag: arg, index: index, args: args), &root)
                index += step.advanceBy
                if let error = step.error { errors.append(error) }
            } else {
                if arg == "--" { positionalOnly = true }
                guard let parser = positional.element(at: positionalIndex) else {
                    errors.append("Unknown argument \(arg.singleQuoted)")
                    break loop
                }
                let step = parser.parse(PositionalInput(index: index, args: args, sawDashDash: positionalOnly), &root)
                index += step.advanceBy
                if let error = step.error { errors.append(error) }
                positionalIndex += 1
            }
        }

        for parser in positional.dropFirst(positionalIndex) {
            if let placeholder = parser.mandatoryPlaceholder {
                errors.append("Argument \(placeholder.singleQuoted) is mandatory")
            }
        }
        for conflictSet in conflictingOptions {
            let mutual = conflictSet.intersection(seenOptions)
            if mutual.count > 1 {
                errors.append("Conflicting options: \(mutual.sorted().joined(separator: ", "))")
                break
            }
        }
        return errors.isEmpty ? .cmd(root) : .failure(errors.joinErrors())
    }
}

extension String {
    /// `-50`: a negative number for `resize`, not a flag.
    fileprivate var isNegativeNumberLike: Bool {
        var iterator = makeIterator()
        return iterator.next() == "-" && iterator.next()?.isNumber == true
    }
}
