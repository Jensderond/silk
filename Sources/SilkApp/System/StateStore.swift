import CoreGraphics
import Foundation

/// Crash-safety state persisted under ~/Library/Application Support/Silk.
///
/// * `hidden.json` — the hide ledger: every window Silk parked in a screen corner, with
///   the frame to restore it to. Written atomically whenever the set changes, so a
///   SIGKILL or crash never strands windows off-screen: the next launch restores them.
/// * `world.json` — the last frozen tree (opaque `Data` from SilkCore), so a relaunch after
///   a crash or upgrade puts windows back on their workspaces.
final class StateStore {
    struct HiddenWindow: Codable, Equatable {
        var windowID: UInt32
        var pid: Int32
        var bundleID: String?
        /// Where the window goes when restored, top-left global coordinates.
        var restoreFrame: CGRect
    }

    private struct Ledger: Codable {
        /// The window server session; window ids are only meaningful within one session.
        var session: String
        var windows: [HiddenWindow]
    }

    private let directory: URL
    private let queue = DispatchQueue(label: "dev.jensderond.silk.state", qos: .utility)
    /// Nil until the first write, so the first call always replaces what a previous run left.
    private var lastWrittenLedger: [UInt32: HiddenWindow]?

    init(directory: URL = StateStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.main.bundleIdentifier?.hasSuffix(".debug") == true ? "Silk Debug" : "Silk")
    }

    private var ledgerURL: URL { directory.appending(path: "hidden.json") }
    private var worldURL: URL { directory.appending(path: "world.json") }

    /// Records the current set of hidden windows. Cheap when nothing changed.
    func recordHidden(_ windows: [UInt32: HiddenWindow]) {
        guard windows != lastWrittenLedger else { return }
        lastWrittenLedger = windows
        let ledger = Ledger(session: Self.sessionID, windows: windows.values.sorted { $0.windowID < $1.windowID })
        write(ledger, to: ledgerURL)
    }

    /// Windows a previous run of Silk (in this login session) left hidden.
    func loadStrandedWindows() -> [HiddenWindow] {
        guard let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data),
              ledger.session == Self.sessionID
        else { return [] }
        return ledger.windows
    }

    func saveWorld(_ data: Data) {
        let url = worldURL
        queue.async { [directory] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    func loadWorld() -> Data? {
        try? Data(contentsOf: worldURL)
    }

    /// Blocks until queued writes are on disk (used right before termination).
    func flush() {
        queue.sync {}
    }

    private func write(_ ledger: Ledger, to url: URL) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        queue.async { [directory] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Identifies the login session: window ids are unique only within it. The session UUID
    /// changes on every login; boot time is the fallback if it is ever missing.
    static let sessionID: String = {
        if let uuid = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionUniqueSessionUUID"] as? String {
            return uuid
        }
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &bootTime, &size, nil, 0)
        return "boot-\(bootTime.tv_sec)"
    }()
}
