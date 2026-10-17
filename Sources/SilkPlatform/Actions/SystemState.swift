import AppKit

/// System facts Silk checks at startup and shows in its menu.
public enum SystemState {
    /// Release and debug bundle ids of AeroSpace.
    public static let aeroSpaceBundleIds = ["bobko.aerospace", "bobko.aerospace.debug"]

    /// Running AeroSpace instances (Silk refuses to manage windows alongside it).
    public static var runningAeroSpace: [NSRunningApplication] {
        aeroSpaceBundleIds.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
    }

    public static var isAeroSpaceRunning: Bool { !runningAeroSpace.isEmpty }

    /// Asks every running AeroSpace to quit. Returns false if any instance refused the request.
    @discardableResult
    public static func quitAeroSpace() -> Bool {
        runningAeroSpace.allSatisfy { $0.terminate() }
    }

    /// Stage Manager (`com.apple.WindowManager GloballyEnabled`) fights tiling; Silk warns about it.
    public static var isStageManagerEnabled: Bool {
        let domain = "com.apple.WindowManager" as CFString
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue("GloballyEnabled" as CFString, domain) as? NSNumber)?.boolValue ?? false
    }

    /// "Displays have separate Spaces" (System Settings > Desktop & Dock).
    public static var screensHaveSeparateSpaces: Bool { NSScreen.screensHaveSeparateSpaces }
}
