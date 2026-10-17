import CoreGraphics
import Foundation

/// Window-server facts about specific windows, via `CGWindowListCreateDescriptionFromArray`
/// (never a full `CGWindowListCopyWindowInfo` scan, never `kCGWindowName`, which needs Screen Recording).
enum WindowServerInfo {
    struct Entry: Equatable {
        var layer: Int
        var isOnScreen: Bool
    }

    /// Entries for the windows the window server still knows; absent ids are gone.
    static func describe(_ ids: [UInt32]) -> [UInt32: Entry] {
        guard !ids.isEmpty else { return [:] }
        let pointers = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        let array = pointers.withUnsafeBufferPointer { buffer in
            CFArrayCreate(nil, UnsafeMutablePointer(mutating: buffer.baseAddress), buffer.count, nil)
        }
        guard let array, let descriptions = CGWindowListCreateDescriptionFromArray(array) as? [[CFString: Any]] else { return [:] }
        var result: [UInt32: Entry] = [:]
        for description in descriptions {
            guard let number = description[kCGWindowNumber] as? NSNumber else { continue }
            result[number.uint32Value] = Entry(
                layer: (description[kCGWindowLayer] as? NSNumber)?.intValue ?? 0,
                isOnScreen: (description[kCGWindowIsOnscreen] as? NSNumber)?.boolValue ?? false
            )
        }
        return result
    }

    static func describe(_ id: UInt32) -> Entry? {
        describe([id])[id]
    }
}
