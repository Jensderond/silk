import CoreGraphics
import Foundation

/// The last frames Silk wrote to one window, used to recognise the `kAXMoved` /
/// `kAXResized` notifications those writes cause ("echoes").
///
/// Position and size are matched independently: a `size, position` write sequence passes
/// through intermediate states (new size at old position) whose notifications must also count
/// as ours, and position-only animation ticks never change the size.
struct EchoRing {
    static let capacity = 8
    static let tolerance: CGFloat = 1
    static let maxAge: TimeInterval = 0.5

    private struct Entry {
        var frame: CGRect
        var time: TimeInterval
    }

    private var entries: [Entry] = []
    private var nextIndex = 0

    mutating func record(_ frame: CGRect, at time: TimeInterval) {
        let entry = Entry(frame: frame, time: time)
        if entries.count < Self.capacity {
            entries.append(entry)
        } else {
            entries[nextIndex] = entry
        }
        nextIndex = (nextIndex + 1) % Self.capacity
    }

    func matchesPosition(_ origin: CGPoint, at time: TimeInterval) -> Bool {
        entries.contains { isFresh($0, time) && close($0.frame.minX, origin.x) && close($0.frame.minY, origin.y) }
    }

    func matchesSize(_ size: CGSize, at time: TimeInterval) -> Bool {
        entries.contains { isFresh($0, time) && close($0.frame.width, size.width) && close($0.frame.height, size.height) }
    }

    /// Whether a moved/resized notification reporting `frame` is an echo of our own writes.
    func isEcho(_ frame: CGRect, kind: FrameChangeKind, at time: TimeInterval) -> Bool {
        switch kind {
            case .moved: matchesPosition(frame.origin, at: time)
            case .resized: matchesSize(frame.size, at: time)
        }
    }

    private func isFresh(_ entry: Entry, _ time: TimeInterval) -> Bool {
        time - entry.time <= Self.maxAge && time >= entry.time
    }

    private func close(_ a: CGFloat, _ b: CGFloat) -> Bool {
        abs(a - b) <= Self.tolerance
    }
}

enum FrameChangeKind {
    case moved, resized
}
