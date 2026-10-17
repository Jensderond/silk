import Foundation

/// Opt-in timing trace for diagnosing latency: `SILK_TRACE=1` logs every platform event and
/// layout flush to stderr with a millisecond timestamp. Off by default; zero cost when off.
enum Trace {
    static let isEnabled = ProcessInfo.processInfo.environment["SILK_TRACE"] == "1"
    private static let start = DispatchTime.now()

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let origin = start.uptimeNanoseconds // initialise the lazy start before reading the clock
        let ms = Double(DispatchTime.now().uptimeNanoseconds - origin) / 1_000_000
        FileHandle.standardError.write(Data((String(format: "[silk %9.1f] ", ms) + message() + "\n").utf8))
    }
}
