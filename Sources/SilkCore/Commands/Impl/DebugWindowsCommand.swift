import Foundation

struct DebugWindowsCommand: ParsableCommand {
    static let kind = CommandKind.debugWindows
    static let help = HelpText.debugWindows
    static let parser = ArgParser<Self>(flags: ["--window-id": .windowId], positional: [])

    var common: CommonArgs
    init(rawArgs: [String]) { common = CommonArgs(rawArgs: rawArgs) }

    static let disclaimer = """
        !!! DISCLAIMER !!!
        !!! 'debug-windows' command is not stable API. Please don't rely on the command existence and output format !!!
        !!! The only intended use case is to report bugs about incorrect windows handling !!!
        """

    func run(_ context: CommandContext) -> Int32 {
        let world = context.world
        let io = context.io
        if let windowId = common.windowId {
            guard let window = world.window(byId: windowId) else {
                return io.fail("Can't find window with the specified window-id: \(windowId)")
            }
            io.out(DebugWindowsRecorder.dump(window, world: world) + "\n")
            io.out(Self.disclaimer)
            return ExitCode.success
        }
        switch world.debugWindowsRecorder.state {
            case .recording:
                io.out(world.debugWindowsRecorder.finish().joined(separator: "\n\n"))
                io.out("\n" + Self.disclaimer + "\n")
                io.out("Debug session finished" + "\n")
                return ExitCode.success
            case .notRecording:
                world.debugWindowsRecorder.start()
                io.out("""
                    Debug windows session has started
                    1. Focus the problematic window
                    2. Run 'aerospace debug-windows' once again to finish the session and get the results
                    """)
                // Make sure that the terminal window that started the recording is recorded first
                guard let target = context.resolveTarget(common) else { return ExitCode.fail }
                if let window = target.window { world.debugWindowsRecorder.record(window, world: world) }
                return ExitCode.success
            case .recordingAborted:
                io.out("""
                    Recording of the previous session was aborted after \(DebugWindowsRecorder.limit) windows has been focused
                    Run the command one more time to start new debug session
                    """)
                world.debugWindowsRecorder.reset()
                return ExitCode.fail
        }
    }
}

/// `debug-windows` session: dumps of every window focused while recording.
struct DebugWindowsRecorder {
    enum State { case recording, notRecording, recordingAborted }

    static let limit = 10
    private(set) var state = State.notRecording
    private var log: [(WindowID, String)] = []

    mutating func start() {
        state = .recording
        log = []
    }

    mutating func finish() -> [String] {
        defer { reset() }
        return log.map(\.1)
    }

    mutating func reset() {
        state = .notRecording
        log = []
    }

    mutating func record(_ window: Window, world: World) {
        guard state == .recording else { return }
        if log.count > Self.limit {
            state = .recordingAborted
            log = []
            return
        }
        if log.contains(where: { $0.0 == window.id }) { return }
        log.append((window.id, Self.dump(window, world: world)))
    }

    /// The core's view of a window as JSON, each line prefixed with `<bundle-id>.<window-id> ||| `.
    static func dump(_ window: Window, world: World) -> String {
        func rect(_ rect: CGRect?) -> Any {
            guard let rect else { return NSNull() }
            return ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
        }
        let matchingRules = world.compiledConfig.onWindowDetected.enumerated()
            .filter { world.matches($0.element, window) }
            .map { "on-window-detected[\($0.offset)]" }
        let info: [String: Any] = [
            "Silk.windowId": window.id,
            "Silk.title": window.title,
            "Silk.kind": window.kind.rawValue,
            "Silk.workspace": window.nodeWorkspace?.name ?? NSNull(),
            "Silk.treeNodeParent": window.parent.map { String(describing: type(of: $0)) } ?? NSNull(),
            "Silk.layoutReason": String(describing: window.layoutReason),
            "Silk.isFullscreen": window.isFullscreen,
            "Silk.isMacosFullscreen": window.isMacosFullscreen,
            "Silk.isMacosMinimized": window.isMacosMinimized,
            "Silk.isHiddenInCorner": window.isHiddenInCorner,
            "Silk.lastKnownFrame": rect(window.lastKnownFrame),
            "Silk.lastAppliedLayoutPhysicalRect": rect(window.lastAppliedLayoutPhysicalRect),
            "Silk.lastFloatingSize": window.lastFloatingSize.map { ["width": $0.width, "height": $0.height] } ?? NSNull(),
            "Silk.App.appBundleId": window.bundleId ?? NSNull(),
            "Silk.App.appName": window.appName ?? NSNull(),
            "Silk.App.pid": Int(window.pid),
            "Silk.on-window-detected": matchingRules,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return json.prefixingLines(with: "\(window.bundleId ?? "nil-bundle-id").\(window.id) ||| ")
    }
}
