import Foundation
import Security

/// Downloads a newer release in the background and installs it on request or when Silk quits.
///
/// * Download: the release's `Silk-<version>.zip` (or `.dmg`) is unpacked into `~/Library/Caches/<bundle id>/Updates`.
/// * Verify: the unpacked app must satisfy the running app's designated requirement (same bundle id,
///   same signing certificate, so the Accessibility grant carries over) and have the expected version.
///   Anything else is discarded and the menu falls back to opening the release page.
/// * Install: the staged app is moved next to the running one and the two are swapped atomically
///   (`renamex_np` with `RENAME_SWAP`), so a crash mid-install leaves one complete app in place.
///   The old bundle is then deleted; the running process keeps its mapped executable until it exits.
///
/// Only the bundled release app installs updates: `swift run` and debug builds (which live in `build/`
/// and are signed as `dev.jensderond.silk.debug`) never do, nor does an app whose folder isn't writable.
@MainActor
final class UpdateInstaller {
    /// The verified app waiting to be installed.
    private(set) var staged: (version: String, app: URL)?
    /// Called on the main thread whenever `staged` changes.
    var onChange: (() -> Void)?
    private var downloading: String?

    private nonisolated static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.main.bundleIdentifier ?? "dev.jensderond.silk")
            .appending(path: "Updates")
    }

    static var canInstall: Bool {
        let app = Bundle.main.bundleURL
        return app.pathExtension == "app" && !LoginItem.isDebugBuild
            && FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path(percentEncoded: false))
    }

    init() {
        // Whatever an earlier run staged is stale: the running build may be newer by now.
        try? FileManager.default.removeItem(at: Self.directory)
    }

    func isStaged(_ release: UpdateChecker.Release) -> Bool {
        staged?.version == release.version
    }

    /// Downloads and verifies `release` unless it is already staged or on its way.
    func prepare(_ release: UpdateChecker.Release) {
        guard Self.canInstall, let downloadURL = release.downloadURL,
              !isStaged(release), downloading != release.version else { return }
        downloading = release.version
        URLSession.shared.downloadTask(with: downloadURL) { [weak self] file, response, error in
            let result: Result<URL, UpdateError>
            if let error {
                result = .failure(.init(error.localizedDescription))
            } else if let file, (response as? HTTPURLResponse)?.statusCode == 200 {
                let isDiskImage = downloadURL.pathExtension == "dmg"
                result = Result { try Self.unpackAndVerify(archive: file, isDiskImage: isDiskImage, version: release.version) }.mapError { $0 as? UpdateError ?? .init("\($0)") }
            } else {
                result = .failure(.init("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.downloading == release.version else { return }
                    self.downloading = nil
                    switch result {
                        case .success(let app):
                            self.staged = (release.version, app)
                            self.onChange?()
                        case .failure(let error):
                            NSLog("Silk: couldn't prepare update %@: %@", release.version, error.message)
                    }
                }
            }
        }.resume()
    }

    /// Swaps the staged app in for the running one. Returns false (and logs why) when it couldn't.
    @discardableResult
    func install() -> Bool {
        guard let staged else { return false }
        self.staged = nil
        guard let current = UpdateChecker.currentVersion, UpdateChecker.isVersion(staged.version, newerThan: current) else { return false }
        let fileManager = FileManager.default
        let app = Bundle.main.bundleURL
        let sibling = app.deletingLastPathComponent().appending(path: ".\(app.deletingPathExtension().lastPathComponent)-\(staged.version).app")
        do {
            try? fileManager.removeItem(at: sibling)
            try fileManager.moveItem(at: staged.app, to: sibling)
            guard renamex_np(sibling.path(percentEncoded: false), app.path(percentEncoded: false), UInt32(RENAME_SWAP)) == 0 else {
                let reason = String(cString: strerror(errno))
                try? fileManager.removeItem(at: sibling)
                throw UpdateError(reason)
            }
            try? fileManager.removeItem(at: sibling) // the old app now
            NSLog("Silk: installed update %@", staged.version)
            return true
        } catch {
            NSLog("Silk: couldn't install update %@: %@", staged.version, (error as? UpdateError)?.message ?? error.localizedDescription)
            return false
        }
    }

    struct UpdateError: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }

    private nonisolated static func unpackAndVerify(archive: URL, isDiskImage: Bool, version: String) throws -> URL {
        let target = directory.appending(path: version)
        let appName = Bundle.main.bundleURL.lastPathComponent
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        if isDiskImage {
            let mount = target.appending(path: "mount")
            try run("/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path(percentEncoded: false),
                    archive.path(percentEncoded: false))
            defer { try? run("/usr/bin/hdiutil", "detach", "-force", mount.path(percentEncoded: false)) }
            try run("/usr/bin/ditto", mount.appending(path: appName).path(percentEncoded: false),
                    target.appending(path: appName).path(percentEncoded: false))
        } else {
            try run("/usr/bin/ditto", "-x", "-k", archive.path(percentEncoded: false), target.path(percentEncoded: false))
        }

        let app = target.appending(path: appName)
        guard let bundle = Bundle(url: app) else { throw UpdateError("the archive has no \(app.lastPathComponent)") }
        let foundVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard foundVersion == version else { throw UpdateError("expected version \(version), found \(foundVersion ?? "none")") }
        try verifySignature(of: app)
        return app
    }

    private nonisolated static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("\(URL(filePath: tool).lastPathComponent) exited with \(process.terminationStatus)") }
    }

    /// The new app must pass the running app's own designated requirement.
    private nonisolated static func verifySignature(of app: URL) throws {
        var selfCode: SecCode?
        var selfStatic: SecStaticCode?
        var requirement: SecRequirement?
        var newStatic: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic,
              SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError("the running app has no designated requirement")
        }
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newStatic) == errSecSuccess, let newStatic else {
            throw UpdateError("couldn't read the new app's signature")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(newStatic, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdateError("signature check failed: \(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")")
        }
    }
}
