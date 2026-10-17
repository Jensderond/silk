/// Parsed arguments of `subscribe [-h|--help] [--all] [--no-send-initial] [<event>...]`.
///
/// AeroSpace handles `subscribe` in the socket server itself, before regular command parsing (it has no
/// command implementation), so Silk's server does the same. The parser is a port of AeroSpace's generic
/// `parseSpecificCmdArgs` specialised to `SubscribeCmdArgs`, including its error texts and quirks
/// (e.g. `subscribe -- focus-changed` is rejected because `--` reaches the event parser).
struct SubscribeArguments: Sendable, Equatable {
    var events: Set<ServerEventType>
    var sendInitial: Bool

    enum ParseResult: Sendable, Equatable {
        case subscribe(SubscribeArguments)
        case help(String)
        /// Exit code is always ``WireProtocol/failureExitCode``.
        case failure(String)
    }

    static let help = "USAGE: subscribe [-h|--help] [--all] [--no-send-initial] [<event>...]"

    /// - Parameter args: the arguments after `subscribe`.
    static func parse(_ args: [String]) -> ParseResult {
        var all = false
        var sendInitial = true
        var events: Set<ServerEventType> = []
        var errors: [String] = []
        var options: Set<String> = []
        var consumedPositional = false
        var positionalOnly = false
        var index = 0

        loop: while index < args.count {
            let arg = args[index]
            if !positionalOnly && (arg == "-h" || arg == "--help") {
                return .help(help)
            }
            if !positionalOnly && isDashFlag(arg) {
                guard arg == "--all" || arg == "--no-send-initial" else {
                    errors.append("Unknown flag '\(arg)'")
                    break loop
                }
                index += 1
                if !options.insert(arg).inserted {
                    errors.append("Duplicated option '\(arg)'")
                }
                if arg == "--all" { all = true } else { sendInitial = false }
            } else {
                if arg == "--" {
                    positionalOnly = true
                }
                guard !consumedPositional else {
                    errors.append("Unknown argument '\(arg)'")
                    break loop
                }
                var end = index
                while end < args.count && !isDashFlag(args[end]) { end += 1 }
                let parsed = parseEventTypes(args[index ..< end])
                index += parsed.advanceBy
                switch parsed.result {
                    case .success(let value): events = value
                    case .failure(let error): errors.append(error.message)
                }
                consumedPositional = true
            }
        }

        if !errors.isEmpty {
            return .failure(joinErrors(errors))
        }
        if !all && events.isEmpty {
            return .failure("Either --all or at least one <event> must be specified")
        }
        if all && !events.isEmpty {
            return .failure("--all conflicts with specifying individual events")
        }
        return .subscribe(SubscribeArguments(events: all ? Set(ServerEventType.allCases) : events, sendInitial: sendInitial))
    }

    private struct ParseError: Error {
        let message: String
    }

    private static func parseEventTypes(_ args: ArraySlice<String>) -> (result: Result<Set<ServerEventType>, ParseError>, advanceBy: Int) {
        var events: Set<ServerEventType> = []
        var duplicateError: String?
        for arg in args {
            guard let event = ServerEventType(rawValue: arg) else {
                let values = "(" + ServerEventType.allCases.map(\.rawValue).joined(separator: "|") + ")"
                return (.failure(ParseError(message: "Can't parse '\(arg)'.\nPossible values: \(values)")), events.count + 1)
            }
            if events.contains(event) {
                duplicateError = "Duplicate event '\(arg)'"
            }
            events.insert(event)
        }
        if let duplicateError {
            return (.failure(ParseError(message: duplicateError)), args.count)
        }
        return (.success(events), args.count)
    }

    /// AeroSpace's `String.isCliDashFlag`.
    private static func isDashFlag(_ arg: String) -> Bool {
        arg != "--" && arg != "-" && arg.hasPrefix("-")
    }

    /// AeroSpace's `[String].joinErrors()`.
    private static func joinErrors(_ errors: [String]) -> String {
        errors.map { error in
            error.split(separator: "\n").enumerated()
                .map { i, line in (i == 0 ? "ERROR: " : "       ") + line }
                .joined(separator: "\n")
        }
        .joined(separator: "\n")
    }
}
