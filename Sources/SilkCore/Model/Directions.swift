/// The axis a tiling container lays its children out along.
enum Orientation: String, Codable, Sendable {
    /// Children side by side (x axis).
    case h
    /// Children stacked (y axis).
    case v

    var opposite: Orientation { self == .h ? .v : .h }
}

enum CardinalDirection: String, CaseIterable, Equatable, Sendable {
    case left, down, up, right

    var orientation: Orientation { self == .up || self == .down ? .v : .h }
    var isPositive: Bool { self == .down || self == .right }
    var opposite: CardinalDirection {
        switch self {
            case .left: .right
            case .down: .up
            case .up: .down
            case .right: .left
        }
    }
    var focusOffset: Int { isPositive ? 1 : -1 }
    var insertionOffset: Int { isPositive ? 1 : 0 }
}

enum DfsNextPrev: String, CaseIterable, Equatable, Sendable {
    case dfsNext = "dfs-next"
    case dfsPrev = "dfs-prev"
}

enum NextPrev: String, CaseIterable, Equatable, Sendable {
    case next, prev
}

enum CardinalOrDfsDirection: Equatable, Sendable, CaseIterable, RawRepresentable {
    case direction(CardinalDirection)
    case dfsRelative(DfsNextPrev)

    static var allCases: [CardinalOrDfsDirection] {
        CardinalDirection.allCases.map(Self.direction) + DfsNextPrev.allCases.map(Self.dfsRelative)
    }

    init?(rawValue: String) {
        if let direction = CardinalDirection(rawValue: rawValue) {
            self = .direction(direction)
        } else if let nextPrev = DfsNextPrev(rawValue: rawValue) {
            self = .dfsRelative(nextPrev)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
            case .direction(let direction): direction.rawValue
            case .dfsRelative(let nextPrev): nextPrev.rawValue
        }
    }
}
