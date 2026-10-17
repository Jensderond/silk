/// The implicit target of a command: what `AEROSPACE_WINDOW_ID` / `AEROSPACE_WORKSPACE` (or the IPC request's
/// `windowId` / `workspace` fields) name. Empty means "the focused window/workspace".
public struct CommandEnv: Equatable, Sendable {
    public var windowId: WindowID?
    public var workspace: String?

    public init(windowId: WindowID? = nil, workspace: String? = nil) {
        self.windowId = windowId
        self.workspace = workspace
    }

    public static let empty = CommandEnv()

    func withWindowId(_ windowId: WindowID) -> CommandEnv { CommandEnv(windowId: windowId, workspace: nil) }
    func withWorkspace(_ workspace: String) -> CommandEnv { CommandEnv(windowId: nil, workspace: workspace) }

    /// The `AEROSPACE_*` variables passed to `exec-and-forget`.
    var environmentVariables: [String: String] {
        var result: [String: String] = [:]
        if let windowId { result[EnvVar.windowId] = String(windowId) }
        if let workspace { result[EnvVar.workspace] = workspace }
        return result
    }
}

/// The outcome of a command: what the CLI prints and exits with.
public struct CommandResult: Equatable, Sendable {
    public var exitCode: Int32
    /// Output lines joined with "\n" (no trailing newline).
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

enum EnvVar {
    static let windowId = "AEROSPACE_WINDOW_ID"
    static let workspace = "AEROSPACE_WORKSPACE"
    static let focusedWorkspace = "AEROSPACE_FOCUSED_WORKSPACE"
    static let prevWorkspace = "AEROSPACE_PREV_WORKSPACE"
}
