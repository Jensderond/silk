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
    func makeAnimationRequest(for plan: LayoutPlan) -> AnimationRequest {
        var request = AnimationRequest(epoch: plan.epoch)
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
            if wasVisible, let current = animator.presentedFrame(window: id) ?? window.lastKnownFrame,
               let slide = switches.outgoing(monitor: hide.monitor) {
                let exit = slide.exitFrame(for: current)
                let displayID = monitors.first { $0.id == hide.monitor }?.displayID ?? CGMainDisplayID()
                request.moves.append(.init(window: id, pid: window.pid, from: current, to: exit, kind: .workspaceOut, displayID: displayID, then: parked))
            } else {
                request.snaps.append(.init(window: id, frame: parked))
            }
        }
        return request
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
        var ledger: [UInt32: StateStore.HiddenWindow] = [:]
        for (id, window) in windows where window.isHidden {
            guard let restore = window.lastVisibleFrame ?? window.lastKnownFrame else { continue }
            ledger[id] = StateStore.HiddenWindow(windowID: id, pid: window.pid, bundleID: nil, restoreFrame: restore)
        }
        stateStore.recordHidden(ledger)
    }
}

/// A workspace switch that slides, with the geometry of its monitor.
struct Slide {
    var monitor: MonitorID
    var frame: CGRect
    var direction: SlideDirection

    /// Where an incoming window starts: one monitor width/height away, but never fully off
    /// screen (the window server rejects or clamps that), so at least 1 pt stays visible.
    func entryFrame(for target: CGRect, size: CGSize) -> CGRect {
        var origin = target.origin
        switch direction {
            case .left: origin.x = min(target.minX + frame.width, frame.maxX - 1)
            case .right: origin.x = max(target.minX - frame.width, frame.minX - size.width + 1)
            case .down: origin.y = min(target.minY + frame.height, frame.maxY - 1)
            case .none: break
        }
        return CGRect(origin: origin, size: size)
    }

    /// Where an outgoing window slides to before it is parked in the hide corner.
    func exitFrame(for current: CGRect) -> CGRect {
        var origin = current.origin
        switch direction {
            case .left: origin.x = max(current.minX - frame.width, frame.minX - current.width + 1)
            case .right: origin.x = min(current.minX + frame.width, frame.maxX - 1)
            case .down: origin.y = min(current.minY + frame.height, frame.maxY - 1)
            case .none: break
        }
        return CGRect(origin: origin, size: current.size)
    }
}

extension [Slide] {
    func incoming(_ target: CGRect) -> Slide? {
        first { $0.frame.contains(CGPoint(x: target.midX, y: target.midY)) }
    }

    func outgoing(monitor: MonitorID) -> Slide? {
        first { $0.monitor == monitor }
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
