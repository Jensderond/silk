/// A parse failure with the exit code the CLI exits with.
struct CmdParsingFailure: Equatable {
    let message: String
    let exitCode: Int32
}

/// The outcome of parsing a command: the command, a `--help` request, or an error.
enum ParsedCmd<T> {
    case cmd(T)
    case help(String)
    case failure(CmdParsingFailure)

    static func failure(_ message: String, exitCode: Int32 = ExitCode.fail) -> ParsedCmd<T> {
        .failure(CmdParsingFailure(message: message, exitCode: exitCode))
    }

    func map<R>(_ transform: (T) -> R) -> ParsedCmd<R> { flatMap { .cmd(transform($0)) } }

    func flatMap<R>(_ transform: (T) -> ParsedCmd<R>) -> ParsedCmd<R> {
        switch self {
            case .cmd(let value): transform(value)
            case .help(let help): .help(help)
            case .failure(let failure): .failure(failure)
        }
    }

    /// Fails with `message` unless `predicate` holds.
    func filter(_ message: @autoclosure () -> String, _ predicate: (T) -> Bool) -> ParsedCmd<T> {
        flatMap { predicate($0) ? .cmd($0) : .failure(message()) }
    }

    /// Fails with `message` if `predicate` holds.
    func filterNot(_ message: @autoclosure () -> String, _ predicate: (T) -> Bool) -> ParsedCmd<T> {
        flatMap { predicate($0) ? .failure(message()) : .cmd($0) }
    }

    var cmdOrNil: T? {
        if case .cmd(let value) = self { value } else { nil }
    }
}

enum ExitCode {
    static let success: Int32 = 0
    /// `false` / `test` mismatch.
    static let conditionalFalse: Int32 = 1
    static let fail: Int32 = 2

    static func from(_ success: Bool) -> Int32 { success ? ExitCode.success : ExitCode.fail }
}
