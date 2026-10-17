import AppKit

/// `NSApplication.ActivationPolicy` as a plain value type.
public enum AppActivationPolicy: String, Sendable, Equatable {
    case regular
    case accessory
    case prohibited

    init(_ policy: NSApplication.ActivationPolicy) {
        switch policy {
            case .regular: self = .regular
            case .accessory: self = .accessory
            case .prohibited: self = .prohibited
            @unknown default: self = .prohibited
        }
    }
}

/// A running application, as reported by `NSWorkspace`.
public struct AppInfo: Sendable, Equatable {
    public var pid: pid_t
    public var bundleId: String?
    public var name: String?
    public var activationPolicy: AppActivationPolicy
    public var bundlePath: String?
    public var execPath: String?

    public init(pid: pid_t, bundleId: String?, name: String?, activationPolicy: AppActivationPolicy, bundlePath: String?, execPath: String?) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
        self.activationPolicy = activationPolicy
        self.bundlePath = bundlePath
        self.execPath = execPath
    }

    init(_ app: NSRunningApplication) {
        self.init(
            pid: app.processIdentifier,
            bundleId: app.bundleIdentifier,
            name: app.localizedName,
            activationPolicy: AppActivationPolicy(app.activationPolicy),
            bundlePath: app.bundleURL?.path,
            execPath: app.executableURL?.path
        )
    }
}
