import CoreGraphics
import SilkAnimation
import SilkConfig
import SilkCore
import SilkIPC
import SilkPlatform

// Value conversions between modules. Each module defines its own vocabulary so it can be
// built and tested alone; the engine is the only place that knows both sides.

extension Monitor {
    init(_ info: MonitorInfo) {
        self.init(id: info.id, name: info.name, frame: info.frame, visibleFrame: info.visibleFrame, isMain: info.isMain)
    }
}

extension SilkCore.WindowKind {
    init(_ kind: SilkPlatform.WindowKind) {
        switch kind {
            case .window: self = .window
            case .dialog: self = .dialog
            case .popup: self = .popup
        }
    }
}

extension SilkCore.ManipulationPhase {
    init(_ phase: SilkPlatform.ManipulationPhase) {
        switch phase {
            case .began: self = .began
            case .changed: self = .changed
            case .ended: self = .ended
        }
    }
}

extension DetectedWindow {
    init(_ snapshot: WindowSnapshot) {
        self.init(
            id: snapshot.id,
            pid: snapshot.pid,
            bundleId: snapshot.bundleId,
            appName: snapshot.appName,
            title: snapshot.title,
            frame: snapshot.frame,
            kind: SilkCore.WindowKind(snapshot.kind),
            isMinimized: snapshot.isMinimized,
            isFullscreen: snapshot.isFullscreen,
            isFocused: snapshot.isFocused
        )
    }
}

extension SilkIPC.ServerEvent {
    init(_ event: SilkCore.ServerEvent) {
        switch event.type {
            case .focusChanged:
                self = .focusChanged(windowId: event.windowId, workspace: event.workspace ?? "")
            case .focusedMonitorChanged:
                self = .focusedMonitorChanged(workspace: event.workspace ?? "", monitorId: event.monitorId ?? 0)
            case .workspaceChanged:
                self = .workspaceChanged(workspace: event.workspace ?? "", prevWorkspace: event.prevWorkspace ?? "")
            case .modeChanged:
                self = .modeChanged(mode: event.mode)
            case .windowDetected:
                self = .windowDetected(windowId: event.windowId ?? 0, workspace: event.workspace, appBundleId: event.appBundleId, appName: event.appName)
            case .bindingTriggered:
                self = .bindingTriggered(mode: event.mode ?? "main", binding: event.binding ?? "")
        }
    }
}

extension HotkeyModifiers {
    init(_ modifiers: Set<Modifier>) {
        self = []
        for modifier in modifiers {
            switch modifier {
                case .cmd: insert(.cmd)
                case .alt: insert(.alt)
                case .ctrl: insert(.ctrl)
                case .shift: insert(.shift)
            }
        }
    }
}

extension SilkConfig.FocusBackend {
    var platformBackend: SilkPlatform.FocusBackend {
        switch self {
            case .appkit: .appKit
            case .skylight: .skylight
        }
    }
}

extension AnimationSettings {
    init(_ config: AnimationConfig) {
        self.init(
            isEnabled: config.enabled && (config.duration > 0 || config.workspaceDuration > 0),
            duration: Double(config.duration) / 1000,
            workspaceDuration: Double(config.workspaceDuration) / 1000,
            curve: MotionCurve(config.curve),
            respectReduceMotion: config.respectReduceMotion
        )
    }
}

extension MotionCurve {
    init(_ curve: AnimationCurve) {
        switch curve {
            case .bezier(let x1, let y1, let x2, let y2): self = .bezier(UnitBezier(x1: x1, y1: y1, x2: x2, y2: y2))
            case .spring(let response, let damping): self = .spring(Spring(response: response, dampingRatio: damping))
            case .linear: self = .linear
        }
    }
}

extension BorderSettings {
    init(_ config: BorderConfig) {
        let color = config.activeColor
        self.init(
            width: CGFloat(config.width),
            color: CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha),
            radius: config.radius.map { CGFloat($0) }
        )
    }
}

/// Feeds animator frames into the platform's AX frame writer.
final class AnimationBridge: SilkAnimation.FrameSink {
    private let writer: FrameWriter

    init(writer: FrameWriter) {
        self.writer = writer
    }

    func submit(_ writes: [SilkAnimation.FrameWrite]) {
        writer.submit(writes.map { write in
            let mode: SilkPlatform.FrameWrite.Mode = switch write.mode {
                case .final: .final
                case .intermediate(let setSize, let sizeFirst): .intermediate(setSize: setSize, sizeFirst: sizeFirst)
            }
            return SilkPlatform.FrameWrite(window: write.window, frame: write.frame, epoch: write.epoch, mode: mode)
        })
    }

    func cost(window: UInt32) -> SilkAnimation.WriteCost {
        let cost = writer.cost(window: window)
        return SilkAnimation.WriteCost(positionLatencyMs: cost.positionMs, sizeLatencyMs: cost.sizeMs, recentTimeout: cost.hadRecentTimeout)
    }
}
