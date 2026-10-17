import CoreGraphics
import Foundation
import SilkConfig
@testable import SilkCore

let testMonitor = Monitor(
    id: "test-monitor",
    name: "Test Monitor",
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    isMain: true
)

/// AeroSpace's unit-test config: no normalizations, horizontal roots, no persistent workspaces.
func testConfig(_ configure: (inout Config) -> Void = { _ in }) -> Config {
    var config = Config()
    config.enableNormalizationFlattenContainers = false
    config.enableNormalizationOppositeOrientationForNestedContainers = false
    config.defaultRootContainerOrientation = .horizontal
    config.persistentWorkspaces = []
    config.exec = ExecConfig()
    configure(&config)
    return config
}

/// A window manager over a fake platform, with helpers to build trees directly (like AeroSpace's `TestWindow`).
final class TestHarness {
    let platform = FakePlatform()
    let delegate = RecordingDelegate()
    let manager: WindowManager
    var now = Date(timeIntervalSince1970: 1_000_000)
    var world: World { manager.world }

    init(config: Config = testConfig(), monitors: [Monitor] = [testMonitor], finishStartup: Bool = true) {
        var clock: (() -> Date)?
        manager = WindowManager(config: config, platform: platform, monitors: monitors, processEnvironment: ["HOME": "/Users/test"], now: { clock?() ?? Date() })
        clock = { [unowned self] in self.now }
        manager.delegate = delegate
        if finishStartup { manager.finishStartup() }
    }

    func workspace(_ name: String) -> Workspace { world.workspace(named: name) }

    var focusedWindowId: WindowID? { world.focus.window?.id }

    /// Binds a new window directly into the tree (no detection callbacks).
    @discardableResult
    func window(
        _ id: WindowID,
        in parent: TreeNode,
        weight: CGFloat = 1,
        pid: pid_t = 0,
        bundleId: String? = "bobko.AeroSpace.test-app",
        appName: String? = "bobko.AeroSpace.test-app",
        title: String? = nil,
        frame: CGRect? = nil
    ) -> Window {
        let window = Window(id: id, pid: pid, bundleId: bundleId, appName: appName, title: title ?? "TestWindow(\(id))", kind: .window, frame: frame)
        window.pendingInitialFrame = nil
        window.bind(to: parent, adaptiveWeight: weight, index: indexBindLast)
        world.windowsById[id] = window
        return window
    }

    @discardableResult
    func hTiles(_ parent: TreeNode, weight: CGFloat = 1) -> TilingContainer {
        TilingContainer(parent: parent, adaptiveWeight: weight, .h, .tiles, index: indexBindLast)
    }

    @discardableResult
    func vTiles(_ parent: TreeNode, weight: CGFloat = 1) -> TilingContainer {
        TilingContainer(parent: parent, adaptiveWeight: weight, .v, .tiles, index: indexBindLast)
    }

    @discardableResult
    func focus(_ window: Window) -> Bool { world.focusWindow(window) }

    /// Runs a config-style script through the public API.
    @discardableResult
    func run(_ script: String) -> CommandResult { manager.run(script: script) }

    /// Runs CLI arguments through the public API.
    @discardableResult
    func run(args: [String], stdin: String = "", env: CommandEnv = .empty) -> CommandResult {
        manager.run(args: args, stdin: stdin, env: env)
    }

    /// Detects a window through the public API.
    @discardableResult
    func detect(
        _ id: WindowID,
        pid: pid_t = 1,
        bundleId: String? = "com.example.app",
        appName: String? = "Example",
        title: String = "",
        frame: CGRect? = CGRect(x: 100, y: 100, width: 800, height: 600),
        kind: WindowKind = .window,
        isFocused: Bool = false,
        isStartup: Bool = false
    ) -> Window? {
        manager.windowDetected(
            DetectedWindow(id: id, pid: pid, bundleId: bundleId, appName: appName, title: title, frame: frame, kind: kind, isFocused: isFocused),
            isStartup: isStartup
        )
        return world.window(byId: id)
    }
}

/// A compact description of a subtree, for asserting tree shapes (AeroSpace's test `LayoutDescription`).
indirect enum LayoutDescription: Equatable, CustomStringConvertible {
    case workspace([LayoutDescription])
    case h_tiles([LayoutDescription])
    case v_tiles([LayoutDescription])
    case h_accordion([LayoutDescription])
    case v_accordion([LayoutDescription])
    case floatingWindowsContainer([LayoutDescription])
    case window(UInt32)
    case macosPopupWindowsContainer
    case macosMinimized
    case macosHiddenAppWindow
    case macosFullscreen

    var description: String {
        switch self {
            case .workspace(let children): "workspace\(children)"
            case .h_tiles(let children): "h_tiles\(children)"
            case .v_tiles(let children): "v_tiles\(children)"
            case .h_accordion(let children): "h_accordion\(children)"
            case .v_accordion(let children): "v_accordion\(children)"
            case .floatingWindowsContainer(let children): "floating\(children)"
            case .window(let id): "window(\(id))"
            case .macosPopupWindowsContainer: "popups"
            case .macosMinimized: "minimized"
            case .macosHiddenAppWindow: "hiddenApps"
            case .macosFullscreen: "fullscreen"
        }
    }
}

extension TreeNode {
    var layoutDescription: LayoutDescription {
        switch self {
            case let window as Window: .window(window.id)
            case let workspace as Workspace: .workspace(workspace.children.map(\.layoutDescription))
            case let container as FloatingWindowsContainer: .floatingWindowsContainer(container.children.map(\.layoutDescription))
            case is MacosMinimizedWindowsContainer: .macosMinimized
            case is MacosFullscreenWindowsContainer: .macosFullscreen
            case is MacosHiddenAppsWindowsContainer: .macosHiddenAppWindow
            case is MacosPopupWindowsContainer: .macosPopupWindowsContainer
            case let container as TilingContainer:
                switch (container.layout, container.orientation) {
                    case (.tiles, .h): .h_tiles(container.children.map(\.layoutDescription))
                    case (.tiles, .v): .v_tiles(container.children.map(\.layoutDescription))
                    case (.accordion, .h): .h_accordion(container.children.map(\.layoutDescription))
                    case (.accordion, .v): .v_accordion(container.children.map(\.layoutDescription))
                }
            default: .window(0)
        }
    }

    var hWeight: CGFloat { getWeight(.h) }
    var vWeight: CGFloat { getWeight(.v) }
}

/// Parses a script the way the tests of AeroSpace do (exec-and-forget and eval allowed).
func parseScript(_ script: String) -> ParsedCmd<Shell<any Command>> {
    CommandRegistry.parse(script: script, allowExecAndForget: true, allowEval: true)
}

extension ParsedCmd {
    var errorOrNil: String? {
        if case .failure(let failure) = self { return failure.message }
        return nil
    }

    var isHelp: Bool {
        if case .help = self { return true }
        return false
    }
}

/// The single parsed command of a script, or nil.
func parseSingle<T: Command>(_ script: String, as _: T.Type) -> T? {
    guard case .cmd(.cmd(let command)) = parseScript(script) else { return nil }
    return command as? T
}
