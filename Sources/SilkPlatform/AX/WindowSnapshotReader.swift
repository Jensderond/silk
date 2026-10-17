import ApplicationServices

/// Static facts about the app a worker serves.
struct AppIdentity {
    var pid: pid_t
    var bundleId: String?
    var name: String?
}

enum SnapshotReadResult {
    /// The snapshot plus the classifier input it was derived from (kept for cheap re-classification).
    case snapshot(WindowSnapshot, AXWindowDump)
    /// The element is gone (`kAXErrorInvalidUIElement`).
    case invalid
    /// Not an `AXWindow` (sheet, drawer, …).
    case notAWindow
    /// The app didn't answer (timeout, still launching, …); worth retrying later.
    case failed(AXError)
}

/// Reads a ``WindowSnapshot`` in as few AX round trips as possible: one batched attribute read,
/// `AXEnabled` only for the buttons the classifier consults, the app's focused window only when
/// the classifier may need it, and one `CGWindowListCreateDescriptionFromArray` for level/on-screen.
enum WindowSnapshotReader {
    private static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXMinimizedAttribute, AXAttribute.fullScreen, kAXCloseButtonAttribute, kAXFullScreenButtonAttribute,
        kAXZoomButtonAttribute, kAXMinimizeButtonAttribute, kAXIdentifierAttribute, kAXMainAttribute, kAXFocusedAttribute,
    ]

    static func read(
        window: AXUIElement, id: UInt32, appElement: AXUIElement, app: AppIdentity, traits: AppTraits, isMouseDown: Bool
    ) -> SnapshotReadResult {
        let (error, values) = window.copyValues(attributes)
        guard error == .success else { return error == .invalidUIElement ? .invalid : .failed(error) }
        let role = values[0]
        if case .failure(let roleError) = role {
            return roleError == .invalidUIElement ? .invalid : .failed(roleError)
        }
        guard role.string == kAXWindowRole else { return .notAWindow }

        let enabledNeeded = WindowClassifier.buttonsNeedingEnabledState(bundleId: traits.bundleId)
        func button(_ index: Int, _ kind: WindowButton) -> AXWindowDump.Button? {
            guard let element = values[index].element else { return nil }
            return AXWindowDump.Button(isEnabled: enabledNeeded.contains(kind) ? element.bool(kAXEnabledAttribute) : nil)
        }
        let serverInfo = WindowServerInfo.describe(id)
        let level = serverInfo.flatMap { $0.isOnScreen ? $0.layer : nil }
        var dump = AXWindowDump(
            windowID: id,
            subrole: values[1].string,
            title: values[2].string,
            identifier: values[11].string,
            isFocused: values[13].bool,
            isMain: values[12].bool,
            closeButton: button(7, .close),
            fullscreenButton: button(8, .fullscreen),
            zoomButton: button(9, .zoom),
            minimizeButton: button(10, .minimize),
            windowLevel: level
        )
        if WindowClassifier.needsAppFocusedWindow(dump) {
            dump.appFocusedWindowID = appElement.element(kAXFocusedWindowAttribute)?.windowID
        }
        let frame = values[3].point.flatMap { origin in values[4].size.map { CGRect(origin: origin, size: $0) } }
        return .snapshot(WindowSnapshot(
            id: id,
            pid: app.pid,
            bundleId: app.bundleId,
            appName: app.name,
            title: dump.title ?? "",
            frame: frame,
            kind: WindowClassifier.classify(dump, app: traits),
            isMinimized: values[5].bool ?? false,
            isFullscreen: values[6].bool ?? false,
            isFocused: dump.isFocused ?? false,
            isMain: dump.isMain ?? false,
            level: level,
            createdDuringMouseDrag: isMouseDown,
            subrole: dump.subrole,
            identifier: dump.identifier
        ), dump)
    }
}
