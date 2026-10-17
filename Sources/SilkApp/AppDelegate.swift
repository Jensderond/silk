import AppKit
import SilkConfig
import SilkPlatform

/// App lifecycle: single instance, AeroSpace hand-off, Accessibility onboarding, signals.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: Engine?
    private let onboarding = AccessibilityOnboarding()
    private var permissionWatch: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    private var bundleId: String { Bundle.main.bundleIdentifier ?? "dev.jensderond.silk" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateOtherInstance() {
            NSApp.terminate(nil)
            return
        }
        installSignalHandlers()
        guard handOffFromAeroSpace() else {
            NSApp.terminate(nil)
            return
        }
        if AccessibilityPermission.isTrusted {
            launchEngine()
        } else {
            awaitAccessibility()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.shutdown()
    }

    // MARK: - Startup steps

    /// Another Silk is already running: bring it forward instead of fighting over windows.
    private func activateOtherInstance() -> Bool {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        return !others.isEmpty
    }

    /// Two tiling window managers fight over every window; offer to quit AeroSpace.
    private func handOffFromAeroSpace() -> Bool {
        guard SystemState.isAeroSpaceRunning else { return true }
        let alert = NSAlert()
        alert.messageText = "AeroSpace is running"
        alert.informativeText = "Silk replaces AeroSpace and reads the same config. Quit AeroSpace and continue?"
        alert.addButton(withTitle: "Quit AeroSpace")
        alert.addButton(withTitle: "Quit Silk")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        _ = SystemState.quitAeroSpace()
        // Wait (briefly) for AeroSpace to move its hidden windows back and release its socket
        let deadline = Date().addingTimeInterval(5)
        while SystemState.isAeroSpaceRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return true
    }

    private func awaitAccessibility() {
        onboarding.show(reason: .firstLaunch, bundleId: bundleId) { [weak self] in
            self?.launchEngine()
        }
    }

    /// Watches for the permission being turned off while Silk runs. AX connections made without
    /// the permission don't recover, so once it is back Silk relaunches itself.
    private func watchAccessibility() {
        permissionWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !AccessibilityPermission.isTrusted, !self.onboarding.isVisible else { return }
                self.engine?.accessibilityRevoked()
                self.onboarding.show(reason: .revoked, bundleId: self.bundleId) { [weak self] in self?.relaunch() }
            }
        }
    }

    /// Starts a fresh instance once this one has exited.
    private func relaunch() {
        let path = Bundle.main.bundleURL.path(percentEncoded: false)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done; open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// Shows the permission walkthrough again (menu bar → Grant Accessibility Permission).
    func showAccessibilityOnboarding() {
        onboarding.show(reason: AccessibilityPermission.isTrusted ? .firstLaunch : .revoked, bundleId: bundleId) { [weak self] in
            self?.relaunch()
        }
    }

    /// `--config-path <file>` (as in AeroSpace) overrides config discovery.
    private var configPathArgument: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--config-path"), arguments.indices.contains(index + 1) else { return nil }
        return URL(filePath: (arguments[index + 1] as NSString).expandingTildeInPath)
    }

    private func launchEngine() {
        let load = configPathArgument.map { ConfigLoader.load(contentsOf: $0) } ?? ConfigLoader.load()
        let engine = Engine(configLoad: load.isFatal ? ConfigLoadResult(config: ConfigLoader.defaultConfig, url: load.url, diagnostics: load.diagnostics, isFatal: true) : load)
        self.engine = engine
        engine.onRequestAccessibility = { [weak self] in self?.showAccessibilityOnboarding() }
        engine.start()
        watchAccessibility()
    }

    // MARK: - Signals

    /// SIGTERM/SIGINT/SIGHUP (`killall Silk`, logout, Ctrl-C in a terminal): restore hidden
    /// windows before exiting, like a normal quit.
    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.engine?.shutdown()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
