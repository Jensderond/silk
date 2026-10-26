import CoreGraphics

/// Native tabs (Finder, Safari, Terminal, …): every tab is a window of its own, and only the selected tab is in
/// `kAXWindows` and on screen. Selecting, opening or closing a tab swaps which window that is, and the incoming
/// tab already has the tab group's frame. Reconciliation pairs a visible window that left with one that arrived
/// at the same frame in the same pass, so the arriving tab can take the leaving tab's slot instead of being laid
/// out as a new window while the old one leaves a gap.
enum TabHandoff {
    struct Candidate: Equatable {
        let id: UInt32
        let frame: CGRect?
    }

    /// Pairs each departing window with the first unpaired arriving window whose frame matches within a point.
    /// Windows without a frame never pair.
    static func pair(departing: [Candidate], arriving: [Candidate]) -> [(departing: UInt32, arriving: UInt32)] {
        var unpaired = arriving
        var pairs: [(departing: UInt32, arriving: UInt32)] = []
        for leaving in departing {
            guard let frame = leaving.frame,
                  let index = unpaired.firstIndex(where: { $0.frame.map { matches($0, frame) } == true })
            else { continue }
            pairs.append((leaving.id, unpaired.remove(at: index).id))
        }
        return pairs
    }

    private static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }
}
