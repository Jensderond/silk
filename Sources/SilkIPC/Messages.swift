import Foundation

/// A command sent by a client: the JSON object AeroSpace calls `ClientRequest`.
///
/// ```json
/// {"args":["workspace","1"],"stdin":"","windowId":null,"workspace":null}
/// ```
///
/// `windowId`/`workspace` carry the client's `AEROSPACE_WINDOW_ID` / `AEROSPACE_WORKSPACE` environment
/// variables. Clients must send both keys (explicit `null` when unset); AeroSpace appends
/// ``missingContextFieldsWarning`` to the answer of a parsed command when either key is absent, which is what
/// ``hasContextFields`` lets the command layer reproduce. A legacy `command` key is ignored.
public struct ClientRequest: Codable, Sendable, Equatable {
    /// CLI arguments without the program name, e.g. `["list-windows", "--all"]`.
    public var args: [String]
    /// Contents fed to the command as standard input (`workspace --stdin`, `eval --stdin`), usually empty.
    public var stdin: String
    /// `AEROSPACE_WINDOW_ID` as seen by the client.
    public var windowId: UInt32?
    /// `AEROSPACE_WORKSPACE` as seen by the client.
    public var workspace: String?
    /// `false` when the decoded JSON lacked the `windowId` or the `workspace` key.
    public var hasContextFields: Bool

    /// The warning AeroSpace appends to `stderr` of a parsed command's answer when ``hasContextFields`` is `false`.
    public static let missingContextFieldsWarning = "\n\nAeroSpace client has sent incomplete JSON request. 'windowId' or/and 'workspace' fields are missing. Please forward your AEROSPACE_WINDOW_ID and AEROSPACE_WORKSPACE environment variables to these JSON fields. If the appropriate environment variables are empty, pass explicit 'null' in the JSON."

    public init(args: [String], stdin: String = "", windowId: UInt32? = nil, workspace: String? = nil) {
        self.args = args
        self.stdin = stdin
        self.windowId = windowId
        self.workspace = workspace
        self.hasContextFields = true
    }

    private enum CodingKeys: String, CodingKey {
        case args, stdin, windowId, workspace
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        args = try container.decode([String].self, forKey: .args)
        stdin = try container.decode(String.self, forKey: .stdin)
        windowId = try container.decodeIfPresent(UInt32.self, forKey: .windowId)
        workspace = try container.decodeIfPresent(String.self, forKey: .workspace)
        hasContextFields = container.contains(.windowId) && container.contains(.workspace)
    }

    /// Always writes both context keys, `null` when unset, in AeroSpace's key order.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(args, forKey: .args)
        try container.encode(stdin, forKey: .stdin)
        try container.encode(windowId, forKey: .windowId)
        try container.encode(workspace, forKey: .workspace)
    }
}

/// The reply to a one-shot command: the JSON object AeroSpace calls `ServerAnswer`.
///
/// ```json
/// {"exitCode":0,"stdout":"1\n2\n3","stderr":"","serverVersionAndHash":"0.21.3-Beta d56e1637…"}
/// ```
///
/// The CLI prints `stdout` and `stderr` (each followed by a newline, when non-empty) and exits with `exitCode`.
public struct ServerAnswer: Codable, Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    /// `"<version> <git hash>"` of the server; see ``IPCEndpoint/VersionReporting``.
    public var serverVersionAndHash: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "", serverVersionAndHash: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.serverVersionAndHash = serverVersionAndHash
    }
}
