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
}
