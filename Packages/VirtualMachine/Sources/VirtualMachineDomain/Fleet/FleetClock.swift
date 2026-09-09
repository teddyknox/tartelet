import Foundation

/// Time source for the fleet watchdog. Injected so deadlines can be tested with a manual clock.
public protocol FleetClock: Sendable {
    var now: Date { get }
    /// Suspends for `duration`. Throws `CancellationError` when the task is cancelled.
    func sleep(for duration: Duration) async throws
}

public struct SystemFleetClock: FleetClock {
    public init() {}

    public var now: Date {
        Date()
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
