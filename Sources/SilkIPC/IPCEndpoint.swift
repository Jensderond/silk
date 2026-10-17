import Foundation

/// A socket path the server listens on, plus the version string it reports there.
public struct IPCEndpoint: Sendable, Hashable, CustomStringConvertible {
    /// What goes into `ServerAnswer.serverVersionAndHash` on this endpoint.
    public enum VersionReporting: Sendable, Hashable {
        /// Always the same string.
        case fixed(String)
        /// The connecting AeroSpace CLI's own version, so it never prints "client/server versions don't match"
        /// (it does after every failing command and on `--version`). The CLI binary is identified by the
        /// socket's peer pid; any other client (custom scripts, older or unrecognised builds) gets `fallback`.
        case mirrorAeroSpaceClient(fallback: String)
    }

    /// Absolute path of the socket file; at most 103 UTF-8 bytes.
    public var path: String
    public var versionReporting: VersionReporting

    public init(path: String, versionReporting: VersionReporting) {
        self.path = path
        self.versionReporting = versionReporting
    }

    /// Silk's own socket, `/tmp/silk-<NSUserName()>.sock`, used by the `silk` CLI.
    public static var silkSocketPath: String { "/tmp/silk-\(NSUserName()).sock" }

    /// AeroSpace's socket path, mirroring the connecting `aerospace` CLI's version
    /// (fallback ``AeroSpaceCompat/targetVersionAndHash``), so brew's `aerospace` and scripts work unmodified.
    public static var aerospace: IPCEndpoint {
        IPCEndpoint(path: AeroSpaceCompat.socketPath, versionReporting: .mirrorAeroSpaceClient(fallback: AeroSpaceCompat.targetVersionAndHash))
    }

    /// Silk's socket, reporting `version` (default: ``SilkVersion/current``).
    public static func silk(version: String = SilkVersion.current) -> IPCEndpoint {
        IPCEndpoint(path: silkSocketPath, versionReporting: .fixed(version))
    }

    public var description: String { path }
}
