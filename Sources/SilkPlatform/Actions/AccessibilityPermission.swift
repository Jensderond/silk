import ApplicationServices
import Foundation

/// Accessibility (TCC) permission handling.
public enum AccessibilityPermission {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt if the process isn't trusted. Returns the current trust state.
    @discardableResult
    public static func prompt() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    /// `tccutil reset Accessibility <bundleId>`. macOS keeps a grant keyed on the old code signature
    /// after an app update ("stale grant"): the switch in System Settings looks on but
    /// `AXIsProcessTrusted()` is false. Resetting removes it so the user can grant it afresh.
    public static func resetGrant(bundleId: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleId]
        try? process.run()
        process.waitUntilExit()
    }

    /// AeroSpace's flow: when untrusted, reset the (possibly stale) grant, prompt once, then poll
    /// every `pollInterval` until trusted and call `onGranted` on the main thread.
    /// Returns a token; cancel it to stop polling.
    public static func waitUntilTrusted(bundleId: String, pollInterval: TimeInterval = 1, onGranted: @escaping () -> Void) -> Cancellable {
        let token = Cancellable()
        if isTrusted {
            DispatchQueue.main.async(execute: onGranted)
            return token
        }
        DispatchQueue.global(qos: .userInitiated).async {
            resetGrant(bundleId: bundleId)
            DispatchQueue.main.async {
                guard !token.isCancelled else { return }
                prompt()
                poll(token, pollInterval, onGranted)
            }
        }
        return token
    }

    private static func poll(_ token: Cancellable, _ interval: TimeInterval, _ onGranted: @escaping () -> Void) {
        guard !token.isCancelled else { return }
        if isTrusted { return onGranted() }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { poll(token, interval, onGranted) }
    }

    /// Stops ``waitUntilTrusted(bundleId:pollInterval:onGranted:)``. Main thread only.
    public final class Cancellable {
        fileprivate var isCancelled = false
        public func cancel() { isCancelled = true }
    }
}
