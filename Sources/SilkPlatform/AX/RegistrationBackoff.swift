import Foundation

/// Retry schedule for registering an app's AX observer, which fails (`kAXErrorCannotComplete`,
/// `kAXErrorNotificationUnsupported`) until the app has finished launching and initialised AX.
///
/// 100, 250, 500, 1000, 2000 ms, then every 2 s until ``maxAttempts`` attempts have failed. After
/// that the worker only retries on external triggers (app activation, reconciliation requests).
struct RegistrationBackoff: Equatable {
    static let delays: [TimeInterval] = [0.1, 0.25, 0.5, 1, 2]
    static let maxAttempts = 30

    private(set) var failedAttempts = 0

    /// Records a failed attempt and returns the delay before the next one, or nil to give up.
    mutating func nextDelay() -> TimeInterval? {
        failedAttempts += 1
        guard failedAttempts < Self.maxAttempts else { return nil }
        return Self.delays[min(failedAttempts - 1, Self.delays.count - 1)]
    }

    mutating func reset() {
        failedAttempts = 0
    }
}
