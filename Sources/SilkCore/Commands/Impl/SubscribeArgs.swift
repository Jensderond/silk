/// `subscribe` arguments. Subscriptions stream events, so the IPC server runs them, not the shell.
struct SubscribeArgs {
    var allAlias = false
    var sendInitial = true
    var events: Set<ServerEventType> = []

    static let parser = ArgParser<SubscribeArgs>(
        flags: [
            "--all": .trueBool(\.allAlias),
            "--no-send-initial": .falseBool(\.sendInitial),
        ],
        positional: [.value(\.events) { input in
            let args = input.nonFlagArgs
            var events: Set<ServerEventType> = []
            var duplicateError: String?
            for arg in args {
                switch parseEnum(arg, ServerEventType.self) {
                    case .success(let event):
                        if events.contains(event) { duplicateError = "Duplicate event '\(arg)'" }
                        events.insert(event)
                    case .failure(let error):
                        return ParsedArg(value: .failure(error), advanceBy: events.count + 1)
                }
            }
            if let duplicateError { return .failure(duplicateError, advanceBy: args.count) }
            return .success(events, advanceBy: args.count)
        }]
    )

    static func parse(_ args: [String]) -> ParsedCmd<SubscribeArgs> {
        parser.parse(SubscribeArgs(), args, help: HelpText.subscribe)
            .filter("Either --all or at least one <event> must be specified") { $0.allAlias || !$0.events.isEmpty }
            .filter("--all conflicts with specifying individual events") { $0.allAlias.implies($0.events.isEmpty) }
            .map { raw in
                guard raw.allAlias else { return raw }
                var normalized = raw
                normalized.events = Set(ServerEventType.allCases)
                normalized.allAlias = false
                return normalized
            }
    }
}
