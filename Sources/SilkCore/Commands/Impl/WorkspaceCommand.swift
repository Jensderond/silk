struct WorkspaceCommand: ParsableCommand {
    static let kind = CommandKind.workspace
    static let help = HelpText.workspace
    static let parser = ArgParser<Self>(
        flags: [
            "--auto-back-and-forth": .constant(\.autoBackAndForthFlag, true),
            "--wrap-around": .constant(\.wrapAroundFlag, true),
            "--fail-if-noop": .trueBool(\.failIfNoop),
            "--stdin": .stdin,
            "--no-stdin": .noStdin,
        ],
        positional: [
            .dashDash(mandatory: false),
            .mandatory(\.target, placeholder: WorkspaceTarget.placeholder, WorkspaceTarget.parse),
        ],
        conflictingOptions: [["--stdin", "--no-stdin"]]
    )

    var common: CommonArgs
    var target = WorkspaceTarget.relative(.next)
    var autoBackAndForthFlag: Bool?
    var failIfNoop = false
    var wrapAroundFlag: Bool?
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    var autoBackAndForth: Bool { autoBackAndForthFlag ?? false }

    static func parse(_ args: [String]) -> ParsedCmd<WorkspaceCommand> {
        parseArgs(args)
            .filter("--wrapAround requires using \(NextPrev.unionLiteral) argument") { ($0.wrapAroundFlag != nil).implies($0.target.isRelative) }
            .filterNot("--auto-back-and-forth is incompatible with \(NextPrev.unionLiteral)") { $0.autoBackAndForthFlag != nil && $0.target.isRelative }
            .filterNot("--fail-if-noop is incompatible with \(NextPrev.unionLiteral)") { $0.failIfNoop && $0.target.isRelative }
            .filterNot("--fail-if-noop is incompatible with --auto-back-and-forth") { $0.autoBackAndForth && $0.failIfNoop }
            .filter("--stdin and --no-stdin require using \(NextPrev.unionLiteral) argument") {
                ($0.common.explicitStdinFlag != nil).implies($0.target.isRelative)
            }
    }

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        guard let focus = context.resolveTarget(common) else { return ExitCode.fail }
        let focusedWorkspace = focus.workspace
        let workspaceName: String
        switch target {
            case .relative(let nextPrev):
                let stdin = common.explicitStdinFlag == true ? context.io.readStdin() : nil
                switch world.nextPrevWorkspace(current: focusedWorkspace, isNext: nextPrev == .next, wrapAround: wrapAroundFlag ?? false, stdin: stdin, target: focus) {
                    case .success(let workspace): workspaceName = workspace.name
                    case .failure(let error): return context.io.fail(error.message)
                }
            case .direct(let name):
                workspaceName = name.raw
                if autoBackAndForth && focusedWorkspace.name == workspaceName {
                    return WorkspaceBackAndForthCommand(rawArgs: []).run(context)
                }
        }
        if focusedWorkspace.name == workspaceName {
            if failIfNoop { return ExitCode.fail }
            return context.io.succeed(warning: "Workspace '\(workspaceName)' is already focused. Tip: use --fail-if-noop to exit with non-zero code")
        }
        return ExitCode.from(world.focusWorkspace(world.workspace(named: workspaceName)))
    }
}

extension World {
    /// The next/previous workspace among those on the current monitor (or the names given on stdin).
    func nextPrevWorkspace(current: Workspace, isNext: Bool, wrapAround: Bool, stdin: String?, target: LiveFocus) -> Result<Workspace, ParseError> {
        let workspaces: [Workspace]
        if let stdin {
            var names: [WorkspaceName] = []
            for raw in stdin.split(whereSeparator: \.isWhitespace).map(String.init) where !raw.isEmpty {
                switch WorkspaceName.parse(raw) {
                    case .success(let name): names.append(name)
                    case .failure(let error): return .failure(error)
                }
            }
            workspaces = names.map { workspace(named: $0.raw) }
        } else {
            let currentMonitor = monitor(of: current)
            var onMonitor = allWorkspaces.filter { monitor(of: $0).id == currentMonitor.id }
            if !onMonitor.contains(where: { $0 === current }) { onMonitor.append(current) }
            workspaces = onMonitor.sorted()
        }
        if workspaces.isEmpty { return .failure(ParseError("The list of workspaces is empty")) }
        let index = workspaces.firstIndex { $0 === target.workspace }.map { isNext ? $0 + 1 : $0 - 1 } ?? 0
        if wrapAround {
            return workspaces.element(wrappingIndex: index).map { .success($0) } ?? .failure(ParseError("List of workspaces is empty"))
        }
        if let workspace = workspaces.element(at: index) { return .success(workspace) }
        return .failure(ParseError(index >= workspaces.count
            ? "Reached the end of the supplied workspaces list"
            : "Rached the beginning of the supplied workspaces list"))
    }
}
