/// A command's stdin/stdout/stderr. Output is collected as lines.
final class CommandIO {
    var stdout: [String] = []
    var stderr: [String] = []
    private var readStdinSource: () -> String

    init(stdin: String) {
        var remaining = stdin
        readStdinSource = {
            defer { remaining = "" }
            return remaining
        }
    }

    /// Shares the stdin of `parent` (pipelines: the first command reads the outer stdin).
    init(forwardingStdinOf parent: CommandIO) {
        readStdinSource = { parent.readStdin() }
    }

    /// Reads all of stdin; later reads return "".
    func readStdin() -> String { readStdinSource() }

    @discardableResult
    func out(_ line: String) -> Self { stdout.append(line); return self }
    @discardableResult
    func out(_ lines: [String]) -> Self { stdout += lines; return self }
    @discardableResult
    func err(_ line: String) -> Self { stderr.append(line); return self }

    /// Reports `message` on stderr and returns the generic failure exit code.
    func fail(_ message: String) -> Int32 {
        err(message)
        return ExitCode.fail
    }

    /// Reports `message` on stderr but succeeds (AeroSpace's "already in state X. Tip: …" messages).
    func succeed(warning message: String) -> Int32 {
        err(message)
        return ExitCode.success
    }
}

/// What a running command can reach.
struct CommandContext {
    let world: World
    let env: CommandEnv
    let io: CommandIO

    func with(env: CommandEnv) -> CommandContext { CommandContext(world: world, env: env, io: io) }
}

let noWindowIsFocused = "No window is focused"

/// For states the parser or the tree invariants should make impossible.
func internalErrorMessage(_ detail: String = "") -> String {
    let suffix = detail.isEmpty ? "" : ": \(detail)"
    return "Internal error\(suffix). Please report it to the Silk issue tracker"
}

extension CommandContext {
    /// AeroSpace `resolveTargetOrReportError`: `--window-id`, `--workspace`, then the env, then the real focus.
    func resolveTarget(_ common: CommonArgs) -> LiveFocus? {
        if let windowId = common.windowId {
            guard let window = world.window(byId: windowId) else {
                io.err("Invalid <window-id> \(windowId) passed to --window-id")
                return nil
            }
            return liveFocusOrReportError(window)
        }
        if let name = common.workspaceName {
            return world.liveFocus(of: world.workspace(named: name.raw))
        }
        if let windowId = env.windowId {
            guard let window = world.window(byId: windowId) else {
                io.err("Invalid <window-id> \(windowId) specified in \(EnvVar.windowId) env variable")
                return nil
            }
            return liveFocusOrReportError(window)
        }
        if let name = env.workspace {
            return world.liveFocus(of: world.workspace(named: name))
        }
        return world.focus
    }

    private func liveFocusOrReportError(_ window: Window) -> LiveFocus? {
        if let focus = world.liveFocusOrNil(window) { return focus }
        io.err("Window \(window.id) doesn't belong to any monitor. And thus can't even define a focused workspace")
        return nil
    }
}
