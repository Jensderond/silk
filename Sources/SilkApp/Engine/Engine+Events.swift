import AppKit
import SilkCore
import SilkPlatform

extension Engine {
    /// Routes one platform event into the core. Called on main, possibly many times per turn.
    func handle(_ event: PlatformEvent) {
        guard manager != nil else { return }
        if Trace.isEnabled { Trace.log("event \(event.traceDescription)") }
        switch event {
            case .windowAppeared(let snapshot, _):
                if snapshot.createdDuringMouseDrag && platform.isLeftMouseDown {
                    detectionsDeferredUntilMouseUp[snapshot.id] = snapshot
                } else {
                    detect(snapshot, isStartup: false)
                }
            case .windowReclassified(let snapshot):
                if detectionsDeferredUntilMouseUp[snapshot.id] != nil {
                    detectionsDeferredUntilMouseUp[snapshot.id] = snapshot
                } else if windows[snapshot.id] == nil {
                    detect(snapshot, isStartup: false)
                } else {
                    manager.windowReclassified(snapshot.id, kind: SilkCore.WindowKind(snapshot.kind))
                }
            case .windowDestroyed(let id):
                if pendingFocus?.window == id { replayDeferredFocus() }
                detectionsDeferredUntilMouseUp[id] = nil
                windows[id] = nil
                animator.cancel(window: id)
                manager.windowDestroyed(id)
            case .windowOrderedOut(let id):
                manager.windowOrderedOut(id)
            case .windowOrderedIn(let id):
                manager.windowOrderedIn(id)
            case .windowTitleChanged(let id, let title):
                manager.windowTitleChanged(id, title: title)
            case .windowMinimizedChanged(let id, let minimized):
                manager.windowMinimizedChanged(id, isMinimized: minimized)
            case .windowFullscreenChanged(let id, let fullscreen):
                manager.windowFullscreenChanged(id, isFullscreen: fullscreen)
            case .userManipulation(let id, let frame, let phase):
                if phase == .began { animator.cancel(window: id) }
                windows[id]?.lastKnownFrame = frame
                windows[id]?.target = nil
                if id == lastFocusedWindow { border?.move(frame: frame) }
                manager.userManipulation(window: id, frame: frame, phase: SilkCore.ManipulationPhase(phase))
                flush()
                return
            case .appChangedFrame(let id, let frame):
                if var window = windows[id] {
                    window.lastKnownFrame = frame
                    if let target = window.target, !window.isHidden, !target.isClose(to: frame, tolerance: 1) {
                        window.needsReassert = true
                    }
                    windows[id] = window
                }
                manager.appChangedFrame(window: id, frame: frame)
            case .frameApplied(let id, let frame):
                windows[id]?.lastKnownFrame = frame
                manager.applied(window: id, presentedFrame: frame)
                return
            case .focusedWindowChanged(let pid, let window):
                guard acceptNativeFocus(window, pid: pid) else { return }
                manager.nativeFocusChanged(window: window, pid: pid)
                reorderBorder()
                updateStatusBar()
            case .appActivated:
                reorderBorder()
                updateStatusBar()
                return
            case .appLaunched(let pid):
                launchTimes[pid] = Date()
                return
            case .appTerminated(let pid):
                launchTimes[pid] = nil
                if let pending = pendingFocus, windows[pending.window]?.pid == pid { replayDeferredFocus() }
                for (id, window) in windows where window.pid == pid {
                    windows[id] = nil
                    animator.cancel(window: id)
                }
                detectionsDeferredUntilMouseUp = detectionsDeferredUntilMouseUp.filter { $0.value.pid != pid }
                manager.appTerminated(pid: pid)
            case .appHidden(let pid):
                manager.appHidden(pid: pid)
            case .appUnhidden(let pid):
                manager.appUnhidden(pid: pid)
            case .monitorsChanged(let monitors):
                animator.screensDidChange()
                manager.monitorsChanged(monitors.map(Monitor.init))
            case .activeSpaceChanged:
                reorderBorder()
            case .willSleep:
                saveWorldIfChanged()
                return
            case .didWake:
                return
            case .screenLocked:
                replayDeferredFocus()
                isScreenLocked = true
                saveWorldIfChanged()
                return
            case .screenUnlocked:
                isScreenLocked = false
            case .leftMouseUp(let point):
                let deferred = detectionsDeferredUntilMouseUp.values.sorted { $0.id < $1.id }
                detectionsDeferredUntilMouseUp = [:]
                for snapshot in deferred { detect(snapshot, isStartup: false) }
                manager.leftMouseUp(at: point)
                flush()
                return
        }
        scheduleFlush()
    }

    /// After Silk asks macOS to focus a window, focus reports naming other windows are stale: they
    /// come from earlier activations that slow apps deliver late. Following them would yank focus
    /// (and the visible workspace) away from what the user just chose. They are ignored until macOS
    /// confirms the requested window, or briefly if it never does.
    /// The last ignored report is replayed when the wait ends without confirmation (the window was
    /// already focused, focusing failed, or the user really did click elsewhere), so the core never
    /// stays out of sync with macOS.
    private func acceptNativeFocus(_ window: UInt32?, pid: pid_t) -> Bool {
        guard var pending = pendingFocus else { return true }
        if window == pending.window || Date() > pending.deadline {
            pendingFocus = nil
            return true
        }
        Trace.log("deferring native focus \(window.map(String.init) ?? "nil"), waiting for \(pending.window)")
        pending.deferred = (window, pid)
        pendingFocus = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + pending.deadline.timeIntervalSinceNow) { [weak self] in
            self?.replayDeferredFocus(pending.id)
        }
        return false
    }

    /// Ends the wait for `id` (if still current) and applies the last report it held back.
    func replayDeferredFocus(_ id: UUID? = nil) {
        guard let pending = pendingFocus, id == nil || pending.id == id else { return }
        pendingFocus = nil
        guard let (window, pid) = pending.deferred else { return }
        manager.nativeFocusChanged(window: window, pid: pid)
        scheduleFlush()
    }

    /// Registers a discovered window with the engine and the core.
    func detect(_ snapshot: WindowSnapshot, isStartup: Bool) {
        if border?.windowNumber == Int(snapshot.id) { return }
        if windows[snapshot.id] == nil {
            windows[snapshot.id] = TrackedWindow(pid: snapshot.pid, lastKnownFrame: snapshot.frame)
        }
        manager.windowDetected(DetectedWindow(snapshot), isStartup: isStartup)
        Trace.log("detected \(snapshot.id) kind \(snapshot.kind)")
        if !isStartup { scheduleFlush() }
    }
}

private extension PlatformEvent {
    /// One short line per event; full reflection of snapshots is far too slow to log per event.
    var traceDescription: String {
        switch self {
            case .windowAppeared(let snapshot, let reconcile):
                "windowAppeared \(snapshot.id) pid \(snapshot.pid) \(snapshot.kind) level \(snapshot.level.map(String.init) ?? "nil")\(reconcile ? " (reconcile)" : "")"
            case .windowReclassified(let snapshot): "windowReclassified \(snapshot.id) \(snapshot.kind)"
            case .monitorsChanged(let monitors): "monitorsChanged \(monitors.count)"
            default: String(describing: self)
        }
    }
}
