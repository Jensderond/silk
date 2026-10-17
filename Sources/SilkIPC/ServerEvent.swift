import Foundation

/// The event kinds `subscribe` accepts, with AeroSpace's CLI spellings.
public enum ServerEventType: String, Codable, CaseIterable, Sendable {
    case focusChanged = "focus-changed"
    case focusedMonitorChanged = "focused-monitor-changed"
    case workspaceChanged = "focused-workspace-changed"
    case modeChanged = "mode-changed"
    case windowDetected = "window-detected"
    case bindingTriggered = "binding-triggered"
}

/// One event streamed to `subscribe` clients, encoded exactly like AeroSpace's `ServerEvent`:
/// sorted keys, unescaped slashes, absent fields omitted.
///
/// ```json
/// {"_event":"focus-changed","windowId":28218,"workspace":"M"}
/// ```
///
/// Build events with the static factories; they set exactly the fields AeroSpace sets for each kind.
public struct ServerEvent: Codable, Sendable, Equatable {
    public let eventType: ServerEventType
    public let windowId: UInt32?
    public let workspace: String?
    public let prevWorkspace: String?
    /// 1-based monitor index.
    public let monitorId: Int?
    public let appBundleId: String?
    public let appName: String?
    public let mode: String?
    public let binding: String?

    private init(
        _ eventType: ServerEventType,
        windowId: UInt32? = nil,
        workspace: String? = nil,
        prevWorkspace: String? = nil,
        monitorId: Int? = nil,
        appBundleId: String? = nil,
        appName: String? = nil,
        mode: String? = nil,
        binding: String? = nil
    ) {
        self.eventType = eventType
        self.windowId = windowId
        self.workspace = workspace
        self.prevWorkspace = prevWorkspace
        self.monitorId = monitorId
        self.appBundleId = appBundleId
        self.appName = appName
        self.mode = mode
        self.binding = binding
    }

    public static func focusChanged(windowId: UInt32?, workspace: String) -> ServerEvent {
        ServerEvent(.focusChanged, windowId: windowId, workspace: workspace)
    }

    public static func focusedMonitorChanged(workspace: String, monitorId oneBased: Int) -> ServerEvent {
        ServerEvent(.focusedMonitorChanged, workspace: workspace, monitorId: oneBased)
    }

    public static func workspaceChanged(workspace: String, prevWorkspace: String) -> ServerEvent {
        ServerEvent(.workspaceChanged, workspace: workspace, prevWorkspace: prevWorkspace)
    }

    public static func modeChanged(mode: String?) -> ServerEvent {
        ServerEvent(.modeChanged, mode: mode)
    }

    public static func windowDetected(windowId: UInt32, workspace: String?, appBundleId: String?, appName: String?) -> ServerEvent {
        ServerEvent(.windowDetected, windowId: windowId, workspace: workspace, appBundleId: appBundleId, appName: appName)
    }

    public static func bindingTriggered(mode: String, binding: String) -> ServerEvent {
        ServerEvent(.bindingTriggered, mode: mode, binding: binding)
    }

    private enum CodingKeys: String, CodingKey {
        case eventType = "_event"
        case windowId, workspace, prevWorkspace, monitorId, appBundleId, appName, mode, binding
    }
}
