/// Arguments shared by all commands.
struct CommonArgs: Equatable {
    /// The arguments after the subcommand name, for `description`.
    var rawArgs: [String]
    /// `--window-id`
    var windowId: WindowID?
    /// `--workspace`
    var workspaceName: WorkspaceName?
    /// `--stdin` / `--no-stdin`
    var explicitStdinFlag: Bool?

    init(rawArgs: [String]) { self.rawArgs = rawArgs }
}

/// A parsed, runnable command.
protocol Command {
    static var kind: CommandKind { get }
    var common: CommonArgs { get set }
    /// The command line as AeroSpace prints it in `config --get` (subcommand plus re-quoted arguments).
    var description: String { get }
    /// Runs the command; returns its exit code.
    func run(_ context: CommandContext) -> Int32
}

extension Command {
    var kind: CommandKind { Self.kind }

    var description: String { ([Self.kind.rawValue] + common.rawArgs).joinArgs() }
}

/// A command parsed from CLI arguments with an `ArgParser`.
protocol ParsableCommand: Command {
    static var help: String { get }
    static var parser: ArgParser<Self> { get }
    init(rawArgs: [String])
    /// Parses and validates; the default just runs `parser`.
    static func parse(_ args: [String]) -> ParsedCmd<Self>
}

extension ParsableCommand {
    static func parse(_ args: [String]) -> ParsedCmd<Self> { parseArgs(args) }

    static func parseArgs(_ args: [String]) -> ParsedCmd<Self> {
        parser.parse(Self(rawArgs: args), args, help: help)
    }
}

// MARK: Common flags

extension FlagParser where Root: Command {
    static var windowId: FlagParser { .single(\.common.windowId, "<window-id>", parseUInt32) }
    static var workspace: FlagParser { .single(\.common.workspaceName, "<workspace>", WorkspaceName.parse) }
    static var stdin: FlagParser { .constant(\.common.explicitStdinFlag, true) }
    static var noStdin: FlagParser { .constant(\.common.explicitStdinFlag, false) }
}

func parseUInt32(_ string: String) -> Result<UInt32, ParseError> {
    UInt32(string).map { .success($0) } ?? .failure(ParseError("Can't convert '\(string)' to UInt32"))
}

/// Parses one positional argument as a raw-value enum.
func parseEnumArg<T: RawRepresentable & CaseIterable>(_ type: T.Type) -> (PositionalInput) -> ParsedArg<T> where T.RawValue == String {
    { input in ParsedArg(value: parseEnum(input.arg, T.self), advanceBy: 1) }
}

/// Parses a flag's value as a raw-value enum; `placeholder` names it when missing.
func parseEnumFlag<T: RawRepresentable & CaseIterable>(_ type: T.Type, missing placeholder: String) -> (FlagInput) -> ParsedArg<T?> where T.RawValue == String {
    { input in
        guard let arg = input.nonFlagArgOrNil else { return .failure("\(placeholder) is mandatory", advanceBy: 0) }
        return ParsedArg(value: parseEnum(arg, T.self).map(Optional.some), advanceBy: 1)
    }
}

func consumeStringArg(_ input: PositionalInput) -> ParsedArg<String> { .success(input.arg, advanceBy: 1) }
