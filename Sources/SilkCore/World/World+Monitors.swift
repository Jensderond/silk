import CoreGraphics
import SilkConfig

extension World {
    /// Monitors ordered left to right, then top to bottom: the order behind 1-based monitor ids.
    var sortedMonitors: [Monitor] {
        monitors.enumerated()
            .sorted { a, b in (a.element.frame.minX, a.element.frame.minY, a.offset) < (b.element.frame.minX, b.element.frame.minY, b.offset) }
            .map(\.element)
    }

    var mainMonitor: Monitor { monitors.first(where: \.isMain) ?? monitors[0] }

    func monitor(id: MonitorID) -> Monitor? { monitors.first { $0.id == id } }

    /// 1-based position in `sortedMonitors`.
    func monitorId1Based(_ monitor: Monitor) -> Int? {
        sortedMonitors.firstIndex { $0.id == monitor.id }.map { $0 + 1 }
    }

    /// 1-based index in `NSScreen.screens` (the order monitors were reported in).
    func appKitScreenIndex(_ monitor: Monitor) -> Int {
        (monitors.firstIndex { $0.id == monitor.id } ?? 0) + 1
    }

    /// The monitor a point belongs to, or the closest one.
    func monitorApproximation(_ point: CGPoint) -> Monitor {
        monitors.min { point.distance(toOuterFrame: $0.frame) < point.distance(toOuterFrame: $1.frame) } ?? mainMonitor
    }

    func resolve(_ pattern: MonitorPattern, sortedMonitors: [Monitor]) -> Monitor? {
        switch pattern {
            case .sequenceNumber(let number): sortedMonitors.element(at: number - 1)
            case .main: mainMonitor
            case .nameRegex(let regex): sortedMonitors.first { regexes.matches($0.name, pattern: regex) }
            case .secondary: sortedMonitors.count == 2 ? sortedMonitors.first { $0.id != mainMonitor.id } : nil
        }
    }

    func value<T>(_ dynamic: DynamicValue<T>, for monitor: Monitor) -> T {
        switch dynamic {
            case .constant(let value):
                return value
            case .perMonitor(let rules, let defaultValue):
                let sorted = sortedMonitors
                return rules.first { resolve($0.monitor, sortedMonitors: sorted)?.id == monitor.id }?.value ?? defaultValue
        }
    }

    func resolvedGaps(_ monitor: Monitor) -> ResolvedGaps {
        let gaps = config.gaps
        return ResolvedGaps(
            innerHorizontal: value(gaps.inner.horizontal, for: monitor),
            innerVertical: value(gaps.inner.vertical, for: monitor),
            outerLeft: value(gaps.outer.left, for: monitor),
            outerRight: value(gaps.outer.right, for: monitor),
            outerTop: value(gaps.outer.top, for: monitor),
            outerBottom: value(gaps.outer.bottom, for: monitor)
        )
    }

    func visibleRectPaddedByOuterGaps(_ monitor: Monitor) -> CGRect {
        let gaps = resolvedGaps(monitor)
        let visible = monitor.visibleFrame
        return CGRect(
            topLeftX: visible.minX + CGFloat(gaps.outerLeft),
            topLeftY: visible.minY + CGFloat(gaps.outerTop),
            width: visible.width - CGFloat(gaps.outerLeft) - CGFloat(gaps.outerRight),
            height: visible.height - CGFloat(gaps.outerTop) - CGFloat(gaps.outerBottom)
        )
    }
}

/// Gaps of one monitor with per-monitor values resolved.
struct ResolvedGaps: Equatable {
    var innerHorizontal: Int
    var innerVertical: Int
    var outerLeft: Int
    var outerRight: Int
    var outerTop: Int
    var outerBottom: Int

    func inner(_ orientation: Orientation) -> Int { orientation == .h ? innerHorizontal : innerVertical }
}
