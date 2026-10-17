import Darwin
import Foundation

/// Silk's own `"<version> <git hash>"`, read from the `Silk.app` bundle that contains the running executable.
///
/// Both the app (`Contents/MacOS/Silk`) and the CLI (`Contents/MacOS/silk`, usually reached through a symlink
/// on `PATH`) live in the same bundle, so they report the same string unless the CLI belongs to a different
/// installation than the running server — exactly the mismatch `silk --version` warns about. The version is
/// `CFBundleShortVersionString`; the hash is the `SilkGitCommit` key written by `scripts/build-app.sh`.
public enum SilkVersion {
    /// Reported by executables that don't run from inside an app bundle (`swift run`, tests).
    public static let unbundled = "0.0.0-SNAPSHOT SNAPSHOT"

    /// The running executable's version string, or ``unbundled``.
    public static let current: String = enclosingAppBundle().flatMap(versionAndHash(of:)) ?? unbundled

    /// `"<CFBundleShortVersionString> <SilkGitCommit>"` of `bundle`, if both keys are present.
    private static func versionAndHash(of bundle: Bundle) -> String? {
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let hash = bundle.object(forInfoDictionaryKey: "SilkGitCommit") as? String
        else { return nil }
        return "\(version) \(hash)"
    }

    /// The nearest `.app` ancestor of the executable, with symlinks resolved.
    private static func enclosingAppBundle() -> Bundle? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        var url = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" { return Bundle(url: url) }
        }
        return nil
    }
}
