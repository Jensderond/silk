import AppKit
import SilkAnimation
import SilkConfig
import SilkCore
import SilkPlatform

/// Per-window state the engine keeps to turn complete plans into minimal animation requests.
struct TrackedWindow {
    var pid: pid_t
    /// The resting frame most recently handed to the animator (where the window is going).
    var target: CGRect?
    /// Last frame read back from the app (snapshot, final-write read-back, app/user changes).
    var lastKnownFrame: CGRect?
    /// Last on-screen resting frame; where the window goes if Silk quits while it's hidden.
    var lastVisibleFrame: CGRect?
    var isHidden = false
    /// The app moved/resized the window away from its tile; re-assert on the next flush.
    var needsReassert = false
    /// Recent re-assertions (fight guard: an app that keeps resisting is left alone).
    var reassertions: [Date] = []
}

extension Engine {
    static let reassertLimit = 3
    static let reassertWindow: TimeInterval = 2
    static let launchSettleTime: TimeInterval = 1.5

    /// Translates a complete plan into the moves and snaps that actually change something.
    /// `parks` hides windows that just left the screen; apply it after `request` (see `flush`).
    /// `revealed` lists windows that came back on screen from a hidden workspace.
    func makeAnimationRequest(for plan: LayoutPlan) -> (request: AnimationRequest, parks: AnimationRequest, revealed: [UInt32]) {
        var request = AnimationRequest(epoch: plan.epoch)
        var parks = AnimationRequest(epoch: plan.epoch)
        var revealed: [UInt32] = []
        let config = manager.config
        let monitors = platform.monitors
        let switches = slidingSwitches(plan, monitors: monitors)

        for (id, target) in plan.frames {
            guard var window = windows[id] else { continue }
            defer { windows[id] = window }
            let wasHidden = window.isHidden
            let wantsReassert = window.needsReassert
            window.needsReassert = false
            let targetChanged = wasHidden || window.target.map({ $0.isClose(to: target) }) != true
            if !targetChanged && !wantsReassert { continue }
            window.isHidden = false
            window.target = target
            window.lastVisibleFrame = target
            if wasHidden { revealed.append(id) }
            // The window already sits there (floating window adopting its own frame, restored layout)
            if !wasHidden, let known = window.lastKnownFrame, known.isClose(to: target) { continue }
            // Only the app moved it: re-assert the tile, unless the app keeps fighting back
            let reassert = !targetChanged && allowReassert(&window)
            if !targetChanged && !reassert { continue }

            let displayID = monitors.displayID(containing: target)
            let current = animator.presentedFrame(window: id) ?? window.lastKnownFrame
            if plan.userDriven.contains(id) || reassert {
                request.snaps.append(.init(window: id, frame: target))
            } else if let initial = plan.newlyPlaced[id] {
                // A launching app can't keep up with per-frame writes; one jump lands sooner and cleaner
                let openStyle = isLaunching(window.pid) ? .none : config.animations.windowOpen
                switch openStyle {
                    case .none: request.snaps.append(.init(window: id, frame: target))
                    case .move: request.moves.append(.init(window: id, pid: window.pid, from: initial, to: target, kind: .open(.move), displayID: displayID))
                    case .popin: request.moves.append(.init(window: id, pid: window.pid, from: initial, to: target, kind: .open(.popIn), displayID: displayID))
                }
            } else if wasHidden, let slide = switches.incoming(target), let size = current?.size {
                let from = slide.entryFrame(for: target, size: size)
                request.moves.append(.init(window: id, pid: window.pid, from: from, to: target, kind: .workspaceIn, displayID: displayID))
            } else if let current, !wasHidden {
                request.moves.append(.init(window: id, pid: window.pid, from: current, to: target, kind: .layout, displayID: displayID))
            } else {
                request.snaps.append(.init(window: id, frame: target))
            }
        }

        for (id, hide) in plan.hidden {
            guard var window = windows[id] else { continue }
            defer { windows[id] = window }
            let size = (animator.presentedFrame(window: id) ?? window.lastKnownFrame ?? window.target)?.size ?? .zero
            let parked = CGRect(origin: hide.origin, size: size)
            if window.isHidden, window.target.map({ $0.origin.isClose(to: parked.origin) }) == true { continue }
            let wasVisible = !window.isHidden
            window.isHidden = true
            window.target = parked
            // Windows leaving the screen park without sliding: macOS keeps 40 pt of a window on screen
            // at the left edge and 1 pt at the right, so a slide-out would bunch them up at the edge.
            if wasVisible {
                parks.snaps.append(.init(window: id, frame: parked))
            } else {
                request.snaps.append(.init(window: id, frame: parked))
            }
        }
        return (request, parks, revealed)
    }

    /// Apps launched in the last 1.5 s are still busy and apply AX frame writes slowly.
    private func isLaunching(_ pid: pid_t) -> Bool {
        launchTimes[pid].map { Date().timeIntervalSince($0) < Self.launchSettleTime } ?? false
    }

    private func allowReassert(_ window: inout TrackedWindow) -> Bool {
        let now = Date()
        window.reassertions.removeAll { now.timeIntervalSince($0) > Self.reassertWindow }
        guard window.reassertions.count < Self.reassertLimit else { return false }
        window.reassertions.append(now)
        return true
    }

    private func slidingSwitches(_ plan: LayoutPlan, monitors: [MonitorInfo]) -> [Slide] {
        guard manager.config.animations.workspaceSwitch == .slide else { return [] }
        return plan.workspaceSwitches.compactMap { change in
            guard change.direction != .none, let monitor = monitors.first(where: { $0.id == change.monitor }) else { return nil }
            return Slide(monitor: change.monitor, frame: monitor.frame, direction: change.direction)
        }
    }

    // MARK: - Animation callbacks

    func animationFrame(window id: UInt32, frame: CGRect) {
        guard id == lastFocusedWindow else { return }
        border?.move(frame: frame)
    }

    func animationCompleted(window id: UInt32, epoch: UInt64) {
        recordHiddenWindows()
    }

    // MARK: - Focus border

    func updateFocusBorder(_ plan: LayoutPlan) {
        let focused = plan.focusedWindow
        guard let border else {
            lastFocusedWindow = focused
            return
        }
        guard let focused, let target = plan.frames[focused] else {
            border.hide()
            lastFocusedWindow = nil
            return
        }
        let frame = animator.presentedFrame(window: focused) ?? target
        if focused != lastFocusedWindow || !border.isVisible {
            border.show(frame: frame, windowNumber: Int(focused))
        } else {
            border.move(frame: frame)
        }
        lastFocusedWindow = focused
    }

    /// Border ordering isn't sticky: re-issue it whenever window ordering may have changed.
    func reorderBorder() {
        border?.reorder()
    }

    // MARK: - Hide ledger

    func recordHiddenWindows() {
        stateStore.recordHidden(restoreFramesForHiddenWindows())
    }

    /// Where each hidden window goes if Silk stops: its last on-screen frame, or (never shown during
    /// this run) centred on its monitor. Never the parked position itself.
    func restoreFramesForHiddenWindows() -> [UInt32: StateStore.HiddenWindow] {
        let hidden = windows.filter { $0.value.isHidden }
        guard !hidden.isEmpty else { return [:] }
        let fallback = hidden.contains { $0.value.lastVisibleFrame == nil } ? manager.terminationFrames() : [:]
        var ledger: [UInt32: StateStore.HiddenWindow] = [:]
        for (id, window) in hidden {
            guard let restore = window.lastVisibleFrame ?? fallback[id] else { continue }
            ledger[id] = StateStore.HiddenWindow(windowID: id, pid: window.pid, bundleID: nil, restoreFrame: restore)
        }
        return ledger
    }
}

/// A workspace switch that slides, with the geometry of its monitor.
struct Slide {
    /// How far incoming windows travel, as a fraction of the monitor size.
    static let distance: CGFloat = 0.2

    var monitor: MonitorID
    var frame: CGRect
    var direction: SlideDirection

    /// Where an incoming window starts: offset against the slide direction, clamped to what the
    /// window server accepts (40 pt visible at the left edge, 1 pt at the right, 32 pt at the bottom).
    func entryFrame(for target: CGRect, size: CGSize) -> CGRect {
        var origin = target.origin
        switch direction {
            case .left: origin.x = min(target.minX + frame.width * Self.distance, frame.maxX - 1)
            case .right: origin.x = max(target.minX - frame.width * Self.distance, frame.minX - size.width + 40)
            case .down: origin.y = min(target.minY + frame.height * Self.distance, frame.maxY - 32)
            case .none: break
        }
        return CGRect(origin: origin, size: size)
    }
}

extension [Slide] {
    func incoming(_ target: CGRect) -> Slide? {
        first { $0.frame.contains(CGPoint(x: target.midX, y: target.midY)) }
    }
}

extension [MonitorInfo] {
    func displayID(containing rect: CGRect) -> CGDirectDisplayID {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return (first { $0.frame.contains(center) } ?? first { $0.isMain } ?? first)?.displayID ?? CGMainDisplayID()
    }
}

extension CGRect {
    /// Equal within half a point on every edge (AX frames are integral; plans may not be).
    func isClose(to other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

extension CGPoint {
    func isClose(to other: CGPoint, tolerance: CGFloat = 0.5) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
    }
}
