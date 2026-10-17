import AppKit
import SilkConfig
import SilkPlatform

/// App lifecycle: single instance, AeroSpace hand-off, Accessibility onboarding, signals.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: Engine?
    private var permissionWait: AccessibilityPermission.Cancellable?
    private let onboarding = MessageWindow()
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
        onboarding.show(
            title: "Welcome to Silk",
            heading: "Silk needs Accessibility permission to move and resize windows.",
            body: """
                1. Click "Open System Settings".
                2. In Privacy & Security → Accessibility, turn on Silk.
                3. Silk starts automatically as soon as permission is granted.

                Silk uses the permission only to arrange windows. It doesn't read their contents, record \
                the screen or send anything over the network.
                """,
            buttons: [
                .init(title: "Quit") { NSApp.terminate(nil) },
                .init(title: "Open System Settings", isDefault: true) {
                    _ = AccessibilityPermission.prompt()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                },
            ]
        )
        permissionWait = AccessibilityPermission.waitUntilTrusted(bundleId: bundleId) { [weak self] in
            MainActor.assumeIsolated {
                self?.onboarding.close()
                self?.permissionWait = nil
                self?.launchEngine()
            }
        }
    }

    private func launchEngine() {
        let load = ConfigLoader.load()
        let engine = Engine(configLoad: load.isFatal ? ConfigLoadResult(config: ConfigLoader.defaultConfig, url: load.url, diagnostics: load.diagnostics, isFatal: true) : load)
        self.engine = engine
        engine.start()
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
