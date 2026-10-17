/// Natural ordering for workspace names: "2" < "10", "a2" < "a10" (AeroSpace `StringLogicalSegments`).
struct LogicalSegments: Comparable, Hashable {
    enum Segment: Comparable, Hashable {
        case number(Int)
        case string(String)

        static func < (lhs: Segment, rhs: Segment) -> Bool {
            switch (lhs, rhs) {
                case (.string(let a), .string(let b)): a < b
                case (.number(let a), .number(let b)): a < b
                case (.number, _): true
                case (.string, _): false
            }
        }
    }

    let segments: [Segment]

    init(_ string: String) {
        var result: [String] = []
        var current = ""
        var isPreviousNumber = false
        for char in string {
            let isNumber = Int(String(char)) != nil
            if isNumber != isPreviousNumber && !current.isEmpty {
                result.append(current)
                current = ""
            }
            current.append(char)
            isPreviousNumber = isNumber
        }
        if !current.isEmpty { result.append(current) }
        segments = result.map { Int($0).map(Segment.number) ?? .string($0) }
    }

    static func < (lhs: LogicalSegments, rhs: LogicalSegments) -> Bool {
        for (a, b) in zip(lhs.segments, rhs.segments) {
            if a < b { return true }
            if b < a { return false }
        }
        return lhs.segments.count < rhs.segments.count
    }
}
