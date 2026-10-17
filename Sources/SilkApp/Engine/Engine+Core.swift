import AppKit
import SilkConfig
import SilkCore
import SilkIPC
import SilkPlatform

// MARK: - Side effects requested by the core

extension Engine: @preconcurrency PlatformActions {
    func focus(window: WindowID, pid: pid_t) {
        platform.focus(window: window, pid: pid)
    }

    func close(window: WindowID) {
        platform.close(window: window)
    }

    func terminateApp(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.terminate() ?? false
    }

    func setMinimized(window: WindowID, _ minimized: Bool) {
        platform.setMinimized(window: window, minimized)
    }

    func setNativeFullscreen(window: WindowID, _ fullscreen: Bool) {
        platform.setFullscreen(window: window, fullscreen)
    }

    func unhideApp(pid: pid_t) {
        platform.unhideApp(pid: pid)
    }

    func execAndForget(_ script: String, env: [String: String]) -> Bool {
        ShellLauncher.launch(script, environment: env)
    }

    func moveMouse(to point: CGPoint) {
        platform.moveMouse(to: point)
    }

    var mouseLocation: CGPoint { platform.mouseLocation }
    var isLeftMouseDown: Bool { platform.isLeftMouseDown }

    func runningApps() -> [SilkCore.AppInfo] {
        platform.runningApps()
            .filter { $0.activationPolicy == .regular }
            .map { app in
                SilkCore.AppInfo(
                    pid: app.pid,
                    bundleId: app.bundleId,
                    name: app.name,
                    execPath: app.execPath,
                    bundlePath: app.bundlePath,
                    isHidden: NSRunningApplication(processIdentifier: app.pid)?.isHidden ?? false
                )
            }
    }

    func volume() -> VolumeState? {
        guard let level = AudioOutput.volume else { return nil }
        return VolumeState(level: level, isMuted: AudioOutput.isMuted ?? false)
    }

    func setVolume(_ state: VolumeState, showHUD: Bool) {
        if AudioOutput.isMuted != state.isMuted { _ = AudioOutput.setMuted(state.isMuted) }
        if !state.isMuted { _ = AudioOutput.setVolume(state.level, autoMuteUnmute: true) }
    }

    func reloadConfig() -> ConfigLoadResult {
        let result = configURL.map { ConfigLoader.load(contentsOf: $0) } ?? ConfigLoader.load()
        if !result.isFatal { configURL = result.url }
        return result
    }

    func broadcast(_ event: SilkCore.ServerEvent) {
        ipcServer?.broadcast(SilkIPC.ServerEvent(event))
    }
}

// MARK: - Notifications from the core

extension Engine: @preconcurrency WindowManagerDelegate {
    func windowManager(_ manager: WindowManager, didActivateMode mode: String?) {
        registerHotkeys()
        updateStatusBar()
    }

    func windowManager(_ manager: WindowManager, didReloadConfig config: Config) {
        platform.focusBackend = config.focusBackend.platformBackend
        applyAppearanceSettings(config)
        LoginItem.set(enabled: config.startAtLogin)
        updateStatusBar()
    }

    func windowManager(_ manager: WindowManager, didChangeConfigMessage message: String?) {
        hasConfigProblems = message != nil
        if let message {
            showConfigMessage(message)
        } else {
            configWindow.close()
        }
        updateStatusBar()
    }

    func windowManagerDidChangeMenuBarState(_ manager: WindowManager) {
        updateStatusBar()
    }

    func windowManager(_ manager: WindowManager, didChangeEnabled isEnabled: Bool) {
        if !isEnabled { border?.hide() }
        registerHotkeys()
        updateStatusBar()
    }
}

/// Runs `exec-and-forget` scripts: `/bin/bash -c`, detached, output discarded (AeroSpace semantics).
enum ShellLauncher {
    private static let queue = DispatchQueue(label: "dev.jensderond.silk.exec", qos: .userInitiated)
    /// Running children, retained until they exit so they're reaped (accessed on `queue`).
    nonisolated(unsafe) private static var running: Set<Process> = []

    static func launch(_ script: String, environment: [String: String]) -> Bool {
        queue.async {
            let process = Process()
            process.terminationHandler = { finished in queue.async { running.remove(finished) } }
            process.executableURL = URL(filePath: "/bin/bash")
            process.arguments = ["-c", script]
            process.environment = environment
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                running.insert(process)
            } catch {
                NSLog("Silk: exec-and-forget failed to start: \(error.localizedDescription)")
            }
        }
        return true
    }
}
