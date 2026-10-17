import AppKit
import ApplicationServices

/// Window tracking, AX notifications and reconciliation. Worker thread only.
extension AppWorker {
    static let reconcileInterval: TimeInterval = 2
    /// Polls for windows that were not on screen yet when detected (classification depends on the level).
    static let onScreenPollDelays: [TimeInterval] = [0.016, 0.05, 0.1, 0.25, 0.5, 1]
    static let popupReclassificationThrottle: TimeInterval = 0.5

    var traits: AppTraits {
        AppTraits(bundleId: identity.bundleId, activationPolicy: AppActivationPolicy(app.activationPolicy))
    }

    func handleNotification(_ name: String, element: AXUIElement, windowID: UInt32?) {
        switch name {
            case kAXWindowCreatedNotification:
                if let window = trackIfNew(element) { announce(window, discoveredByReconcile: false) }
            case kAXFocusedWindowChangedNotification:
                focusedWindowChanged(to: element)
            case kAXMainWindowChangedNotification:
                if let window = trackIfNew(element) {
                    announce(window, discoveredByReconcile: false)
                    reconcile()
                }
            case kAXUIElementDestroyedNotification:
                if let windowID { windowGone(windowID) }
            case kAXMovedNotification:
                if let windowID { frameChanged(windowID, .moved) }
            case kAXResizedNotification:
                if let windowID { frameChanged(windowID, .resized) }
            case kAXWindowMiniaturizedNotification:
                if let windowID { minimizedChanged(windowID, true) }
            case kAXWindowDeminiaturizedNotification:
                if let windowID { minimizedChanged(windowID, false) }
            case kAXTitleChangedNotification:
                if let windowID { titleChanged(windowID) }
            default:
                break
        }
    }

    // MARK: - Tracking

    /// Starts tracking `element` if it is an unknown window: subscribes to its notifications first
    /// (so no change after the snapshot read is missed), then reads the snapshot.
    func trackIfNew(_ element: AXUIElement) -> TrackedWindow? {
        guard let id = element.windowID, windows[id] == nil, let observer else { return nil }
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
        guard let subscribed = subscribe(element, id: id, observer: observer, existing: []) else { return nil }
        let result = WindowSnapshotReader.read(
            window: element, id: id, appElement: appElement, app: identity, traits: traits,
            isMouseDown: InputState.isLeftMouseDown
        )
        guard case .snapshot(let snapshot, let dump) = result else {
            removeSubscriptions(element, subscribed)
            if case .failed = result { hasFailedReads = true }
            updateReconcileTimer()
            return nil
        }
        trackingCounter += 1
        let window = TrackedWindow(id: id, element: element, trackingOrder: trackingCounter, snapshot: snapshot, dump: dump)
        window.subscribed = subscribed
        windows[id] = window
        environment.directory.register(id, self)
        if snapshot.level == nil { pollUntilOnScreen(id, attempt: 0) }
        updateReconcileTimer()
        return window
    }

    func announce(_ window: TrackedWindow, discoveredByReconcile: Bool) {
        environment.emit(.windowAppeared(window.snapshot, discoveredByReconcile: discoveredByReconcile))
    }

    /// Adds the per-window notifications missing from `existing`. Returns nil when the element is
    /// already gone (`kAXUIElementDestroyed` couldn't be registered because the element is invalid).
    private func subscribe(_ element: AXUIElement, id: UInt32, observer: AXObserver, existing: Set<String>) -> Set<String>? {
        var subscribed = existing
        let refcon = UnsafeMutableRawPointer(bitPattern: UInt(id))
        for name in TrackedWindow.notifications where !subscribed.contains(name) {
            let error = AXObserverAddNotification(observer, element, name as CFString, refcon)
            switch error {
                case .success, .notificationAlreadyRegistered: subscribed.insert(name)
                case .invalidUIElement:
                    removeSubscriptions(element, subscribed)
                    return nil
                default: break
            }
        }
        return subscribed
    }

    private func removeSubscriptions(_ element: AXUIElement, _ names: Set<String>) {
        guard let observer else { return }
        for name in names { AXObserverRemoveNotification(observer, element, name as CFString) }
    }

    func unsubscribe(_ window: TrackedWindow) {
        removeSubscriptions(window.element, window.subscribed)
        window.subscribed = []
    }

    func windowGone(_ id: UInt32) {
        guard let window = windows.removeValue(forKey: id) else { return }
        unsubscribe(window)
        environment.directory.unregister(id)
        environment.writer.forget(window: id, target: self)
        if focusedWindowID == id { focusedWindowID = nil }
        if manipulatedWindowID == id { manipulatedWindowID = nil }
        environment.emit(.windowDestroyed(id))
        updateReconcileTimer()
    }

    // MARK: - Notification handlers

    private func focusedWindowChanged(to element: AXUIElement) {
        guard !environment.screenLock.isLocked else { return }
        let id = element.windowID
        if let window = trackIfNew(element) {
            announce(window, discoveredByReconcile: false)
            reconcile()
        }
        focusedWindowID = id
        if let id { confirmFocusVerification(id) }
        environment.emit(.focusedWindowChanged(pid: pid, window: id))
    }

    private func frameChanged(_ id: UInt32, _ kind: FrameChangeKind) {
        guard let window = windows[id] else { return }
        let (error, values) = window.element.copyValues([kAXPositionAttribute, kAXSizeAttribute, AXAttribute.fullScreen])
        if error == .invalidUIElement { return windowGone(id) }
        guard error == .success else { return }
        if case .failure(.invalidUIElement) = values[0] { return windowGone(id) }
        guard let origin = values[0].point, let size = values[1].size else { return }
        let frame = CGRect(origin: origin, size: size)
        window.snapshot.frame = frame

        // No AX notification exists for native fullscreen; transitions show up as resizes.
        if let isFullscreen = values[2].bool, isFullscreen != window.snapshot.isFullscreen {
            window.snapshot.isFullscreen = isFullscreen
            environment.emit(.windowFullscreenChanged(id, isFullscreen))
            return
        }
        if window.echo.isEcho(frame, kind: kind, at: MonotonicClock.now()) { return }

        if manipulatedWindowID == id {
            environment.emit(.userManipulation(id, frame: frame, phase: .changed))
        } else if InputState.isLeftMouseDown && focusedWindowID == id && app.isActive {
            manipulatedWindowID = id
            environment.emit(.userManipulation(id, frame: frame, phase: .began))
        } else {
            environment.emit(.appChangedFrame(id, frame))
        }
        if window.snapshot.kind == .popup { reclassify(window, throttled: true) }
    }

    private func minimizedChanged(_ id: UInt32, _ isMinimized: Bool) {
        guard let window = windows[id], window.snapshot.isMinimized != isMinimized else { return }
        window.snapshot.isMinimized = isMinimized
        environment.emit(.windowMinimizedChanged(id, isMinimized))
    }

    private func titleChanged(_ id: UInt32) {
        guard let window = windows[id] else { return }
        let (error, value) = window.element.copyValue(kAXTitleAttribute)
        if error == .invalidUIElement { return windowGone(id) }
        let title = value as? String ?? ""
        guard title != window.snapshot.title else { return }
        window.snapshot.title = title
        window.dump.title = title
        environment.emit(.windowTitleChanged(id, title))
    }

    // MARK: - Reconciliation

    /// One `kAXWindows` read, diffed against the tracked windows. Adds unknown windows, orders out
    /// windows that are still valid but absent and off screen, orders in returning ones, detects
    /// destroyed windows by `kAXErrorInvalidUIElement` (never by mere absence), and re-classifies
    /// popups and not-yet-on-screen windows. With `collect`, new windows are returned instead of announced.
    @discardableResult
    func reconcile(discoveredByReconcile: Bool = true, collect: Bool = false) -> [WindowSnapshot] {
        guard isRegistered, let observer, !environment.screenLock.isLocked else { return [] }
        let (error, elements) = appElement.elements(kAXWindowsAttribute)
        guard error == .success || error == .noValue else {
            hasFailedReads = true
            updateReconcileTimer()
            return []
        }
        hasFailedReads = false
        var collected: [WindowSnapshot] = []
        func add(_ window: TrackedWindow) {
            if collect { collected.append(window.snapshot) } else { announce(window, discoveredByReconcile: discoveredByReconcile) }
        }

        var present = Set<UInt32>()
        for element in elements {
            guard let id = element.windowID else { continue }
            present.insert(id)
            if let window = windows[id] {
                if window.isOrderedOut {
                    window.isOrderedOut = false
                    environment.emit(.windowOrderedIn(id))
                }
                if !window.isFullySubscribed {
                    window.subscribed = subscribe(window.element, id: id, observer: observer, existing: window.subscribed) ?? window.subscribed
                }
            } else if let window = trackIfNew(element) {
                add(window)
            }
        }
        if let focused = appElement.element(kAXFocusedWindowAttribute) {
            if let window = trackIfNew(focused) { add(window) }
            focusedWindowID = focused.windowID
        }

        let absent = windows.values.filter { !present.contains($0.id) }
        if !absent.isEmpty {
            let serverInfo = WindowServerInfo.describe(absent.map(\.id))
            for window in absent where serverInfo[window.id]?.isOnScreen != true {
                if window.element.copyValue(kAXRoleAttribute).error == .invalidUIElement {
                    windowGone(window.id)
                    continue
                }
                if !window.isOrderedOut && !window.snapshot.isMinimized && !window.snapshot.isFullscreen && !app.isHidden {
                    window.isOrderedOut = true
                    environment.emit(.windowOrderedOut(window.id))
                }
            }
        }
        for window in windows.values where present.contains(window.id) && (window.snapshot.kind == .popup || window.snapshot.level == nil) {
            reclassify(window, throttled: false)
        }
        updateReconcileTimer()
        return collected
    }

    /// Full snapshot re-read; emits `windowReclassified` when kind or level changed.
    private func reclassify(_ window: TrackedWindow, throttled: Bool) {
        let now = MonotonicClock.now()
        if throttled && now - window.lastReclassification < Self.popupReclassificationThrottle { return }
        window.lastReclassification = now
        switch WindowSnapshotReader.read(
            window: window.element, id: window.id, appElement: appElement, app: identity, traits: traits, isMouseDown: false
        ) {
            case .snapshot(var snapshot, let dump):
                snapshot.createdDuringMouseDrag = window.snapshot.createdDuringMouseDrag
                let changed = snapshot.kind != window.snapshot.kind || snapshot.level != window.snapshot.level
                window.snapshot = snapshot
                window.dump = dump
                if changed { environment.emit(.windowReclassified(snapshot)) }
            case .invalid:
                windowGone(window.id)
            case .notAWindow, .failed:
                break
        }
    }

    /// Cheap re-check for a window that was detected before it was on screen: only the window
    /// server is asked; the stored classifier input is re-evaluated with the new level.
    private func pollUntilOnScreen(_ id: UInt32, attempt: Int) {
        guard attempt < Self.onScreenPollDelays.count else { return }
        _ = schedule(after: Self.onScreenPollDelays[attempt]) { [self] in
            guard let window = windows[id], window.snapshot.level == nil else { return }
            guard let entry = WindowServerInfo.describe(id), entry.isOnScreen else {
                return pollUntilOnScreen(id, attempt: attempt + 1)
            }
            window.dump.windowLevel = entry.layer
            window.snapshot.level = entry.layer
            window.snapshot.kind = WindowClassifier.classify(window.dump, app: traits)
            environment.emit(.windowReclassified(window.snapshot))
            updateReconcileTimer()
        }
    }

    /// Reconciles every 2 s while something is unresolved: failed reads, missing window
    /// subscriptions, ordered-out windows or windows not yet on screen.
    func updateReconcileTimer() {
        let isDirty = hasFailedReads || windows.values.contains {
            !$0.isFullySubscribed || $0.isOrderedOut || $0.snapshot.level == nil
        }
        if !isDirty {
            cancel(&reconcileTimer)
        } else if reconcileTimer == nil {
            reconcileTimer = schedule(after: Self.reconcileInterval) { [self] in
                reconcileTimer = nil
                reconcile()
            }
        }
    }

    // MARK: - External triggers

    func handleActivation() {
        retryRegistrationIfNeeded()
        guard isRegistered, !environment.screenLock.isLocked else { return }
        reconcile()
        environment.emit(.focusedWindowChanged(pid: pid, window: focusedWindowID))
    }

    func handleLeftMouseUp() {
        if let id = manipulatedWindowID {
            manipulatedWindowID = nil
            if let window = windows[id], let frame = window.element.frame().frame {
                window.snapshot.frame = frame
                environment.emit(.userManipulation(id, frame: frame, phase: .ended))
            }
        }
        reconcile()
    }

    /// Native fullscreen has no AX notification: re-read `AXFullScreen` after a Space change.
    func handleSpaceChange() {
        guard !environment.screenLock.isLocked else { return }
        for window in windows.values {
            let (error, value) = window.element.copyValue(AXAttribute.fullScreen)
            if error == .invalidUIElement {
                windowGone(window.id)
                continue
            }
            if let isFullscreen = (value as? NSNumber)?.boolValue, isFullscreen != window.snapshot.isFullscreen {
                window.snapshot.isFullscreen = isFullscreen
                environment.emit(.windowFullscreenChanged(window.id, isFullscreen))
            }
        }
        reconcile()
    }

    func enumerate(_ completion: @escaping ([WindowSnapshot]) -> Void) {
        completion(reconcile(collect: true))
    }
}
