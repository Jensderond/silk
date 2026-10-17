import SilkConfig

/// A validated workspace name.
struct WorkspaceName: Equatable, Hashable {
    let raw: String

    private static let reserved: Set<String> = [
        "focused", "non-focused", "visible", "invisible", "non-visible", "active", "non-active", "inactive",
        "back-and-forth", "back_and_forth", "previous", "prev", "next", "monitor", "workspace", "monitors",
        "workspaces", "all", "none", "mouse", "target",
    ]

    static func parse(_ raw: String) -> Result<WorkspaceName, ParseError> {
        if reserved.contains(raw) { return .failure(ParseError("'\(raw)' is a reserved workspace name")) }
        if raw.isEmpty { return .failure(ParseError("Empty workspace name is forbidden")) }
        if raw.contains(",") { return .failure(ParseError("Workspace names are not allowed to contain comma")) }
        if raw.hasPrefix("_") { return .failure(ParseError("Workspace names starting with underscore are reserved for future use")) }
        // The syntax conflicts with CLI options. E.g. list-windows --workspace -foo
        if raw.hasPrefix("-") { return .failure(ParseError("Workspace names starting with dash are disallowed")) }
        if raw.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return .failure(ParseError("Whitespace characters are forbidden in workspace names"))
        }
        return .success(WorkspaceName(raw: raw))
    }
}

/// `workspace` / `move-node-to-workspace` target.
enum WorkspaceTarget: Equatable {
    case relative(NextPrev)
    case direct(WorkspaceName)

    var isRelative: Bool {
        if case .relative = self { true } else { false }
    }

    static let placeholder = "(<workspace-name>|next|prev)"

    static func parse(_ input: PositionalInput) -> ParsedArg<WorkspaceTarget> {
        switch (input.arg, input.sawDashDash) {
            case ("next", false): .success(.relative(.next), advanceBy: 1)
            case ("prev", false): .success(.relative(.prev), advanceBy: 1)
            default: ParsedArg(value: WorkspaceName.parse(input.arg).map(WorkspaceTarget.direct), advanceBy: 1)
        }
    }
}

/// `focus-monitor` / `move-node-to-monitor` / `move-workspace-to-monitor` target.
enum MonitorTarget: Equatable {
    case direction(CardinalDirection)
    case relative(NextPrev)
    case patterns([MonitorPattern])

    var isPatterns: Bool {
        if case .patterns = self { true } else { false }
    }

    var directionOrNil: CardinalDirection? {
        if case .direction(let direction) = self { direction } else { nil }
    }

    static var casesExceptPatterns: [String] { CardinalDirection.cliArgsCases + NextPrev.cliArgsCases }
    static var cases: [String] { casesExceptPatterns + ["<monitor-pattern>"] }

    static func parse(_ input: PositionalInput) -> ParsedArg<MonitorTarget> {
        if !input.sawDashDash {
            if let nextPrev = NextPrev(rawValue: input.arg) { return .success(.relative(nextPrev), advanceBy: 1) }
            if let direction = CardinalDirection(rawValue: input.arg) { return .success(.direction(direction), advanceBy: 1) }
        }
        let args = input.nonFlagArgs
        var patterns: [MonitorPattern] = []
        for arg in args {
            switch parseMonitorPattern(arg) {
                case .success(let pattern): patterns.append(pattern)
                case .failure(let error): return ParsedArg(value: .failure(error), advanceBy: args.count)
            }
        }
        return .success(.patterns(patterns), advanceBy: args.count)
    }
}

/// AeroSpace `parseMonitorDescription`.
func parseMonitorPattern(_ raw: String) -> Result<MonitorPattern, ParseError> {
    if let number = Int(raw) {
        return number >= 1
            ? .success(.sequenceNumber(number))
            : .failure(ParseError("Monitor sequence numbers uses 1-based indexing. Values less than 1 are illegal"))
    }
    switch raw {
        case "main": return .success(.main)
        case "secondary": return .success(.secondary)
        case "": return .failure(ParseError("Empty string is an illegal monitor description"))
        default:
            do throws(ParseError) {
                _ = try CaseInsensitiveRegex(raw)
                return .success(.nameRegex(raw))
            } catch {
                return .failure(error)
            }
    }
}

/// `--monitor` values of `list-windows` / `list-workspaces`.
enum MonitorIdFilter: Equatable {
    case focused, all, mouse
    /// 0-based index into the sorted monitors.
    case index(Int)

    static func parseList(_ input: FlagInput) -> ParsedArg<[MonitorIdFilter]> {
        let args = input.nonFlagArgs
        let possibleValues = "<monitor> possible values: (<monitor-id>|focused|mouse|all)"
        if args.isEmpty { return .failure("<monitor>... is mandatory. \(possibleValues)", advanceBy: 0) }
        var result: [MonitorIdFilter] = []
        for (i, arg) in args.enumerated() {
            if let number = Int(arg) {
                result.append(.index(number - 1))
            } else if arg == "mouse" {
                result.append(.mouse)
            } else if arg == "all" {
                result.append(.all)
            } else if arg == "focused" {
                result.append(.focused)
            } else {
                return .failure("Can't parse monitor ID '\(arg)'. \(possibleValues)", advanceBy: i + 1)
            }
        }
        return .success(result, advanceBy: result.count)
    }
}

enum ToggleState: Equatable {
    case on, off, toggle

    static func parse(_ input: PositionalInput) -> ParsedArg<ToggleState> {
        switch input.arg {
            case "on": .success(.on, advanceBy: 1)
            case "off": .success(.off, advanceBy: 1)
            default: .failure("Can't parse '\(input.arg)'. Possible values: on|off", advanceBy: 1)
        }
    }
}
