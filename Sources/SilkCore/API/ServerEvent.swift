import Foundation

/// Event kinds a `subscribe` client can ask for.
public enum ServerEventType: String, Codable, CaseIterable, Sendable {
    case focusChanged = "focus-changed"
    case focusedMonitorChanged = "focused-monitor-changed"
    case workspaceChanged = "focused-workspace-changed"
    case modeChanged = "mode-changed"
    case windowDetected = "window-detected"
    case bindingTriggered = "binding-triggered"
}

/// An event streamed to `subscribe` clients. Encodes to the same JSON as AeroSpace (`_event` plus the
/// non-nil fields, sorted keys).
public struct ServerEvent: Codable, Equatable, Sendable {
    public let type: ServerEventType
    public let windowId: WindowID?
    public let workspace: String?
    public let prevWorkspace: String?
    /// 1-based monitor sequence number.
    public let monitorId: Int?
    public let appBundleId: String?
    public let appName: String?
    public let mode: String?
    public let binding: String?

    private init(
        _ type: ServerEventType,
        windowId: WindowID? = nil,
        workspace: String? = nil,
        prevWorkspace: String? = nil,
        monitorId: Int? = nil,
        appBundleId: String? = nil,
        appName: String? = nil,
        mode: String? = nil,
        binding: String? = nil
    ) {
        self.type = type
        self.windowId = windowId
        self.workspace = workspace
        self.prevWorkspace = prevWorkspace
        self.monitorId = monitorId
        self.appBundleId = appBundleId
        self.appName = appName
        self.mode = mode
        self.binding = binding
    }

    public static func focusChanged(windowId: WindowID?, workspace: String) -> ServerEvent {
        ServerEvent(.focusChanged, windowId: windowId, workspace: workspace)
    }

    public static func focusedMonitorChanged(workspace: String, monitorId: Int) -> ServerEvent {
        ServerEvent(.focusedMonitorChanged, workspace: workspace, monitorId: monitorId)
    }

    public static func workspaceChanged(workspace: String, prevWorkspace: String) -> ServerEvent {
        ServerEvent(.workspaceChanged, workspace: workspace, prevWorkspace: prevWorkspace)
    }

    public static func modeChanged(mode: String?) -> ServerEvent {
        ServerEvent(.modeChanged, mode: mode)
    }

    public static func windowDetected(windowId: WindowID, workspace: String?, appBundleId: String?, appName: String?) -> ServerEvent {
        ServerEvent(.windowDetected, windowId: windowId, workspace: workspace, appBundleId: appBundleId, appName: appName)
    }

    public static func bindingTriggered(mode: String, binding: String) -> ServerEvent {
        ServerEvent(.bindingTriggered, mode: mode, binding: binding)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "_event"
        case windowId, workspace, prevWorkspace, monitorId, appBundleId, appName, mode, binding
    }

    /// The JSON payload of one event message (AeroSpace's encoder settings: sorted keys, unescaped slashes).
    public func jsonData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        // Encoding plain strings and integers can't fail.
        return (try? encoder.encode(self)) ?? Data()
    }
}
