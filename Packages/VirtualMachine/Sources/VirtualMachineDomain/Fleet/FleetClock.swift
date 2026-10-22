import Foundation

/// A moment as the fleet sees it: the wall clock for people and logs, and the host's awake time
/// for deadlines.
///
/// `uptime` stands still while the host sleeps. A deadline measured on it never charges a guest
/// for a sleep gap the guest could not have used: on 2026-10-22 a lid-closed host that slept
/// between polls tripped a 5-minute boot deadline after 16 wall-clock minutes of which the host
/// had been awake for under three.
public struct FleetInstant: Equatable, Sendable {
    public let date: Date
    /// Seconds the host has been awake since an arbitrary origin.
    public let uptime: TimeInterval

    public init(date: Date, uptime: TimeInterval) {
        self.date = date
        self.uptime = uptime
    }

    /// Awake time elapsed since `earlier`.
    public func awakeTime(since earlier: Self) -> TimeInterval {
        uptime - earlier.uptime
    }

    /// Wall-clock time elapsed since `earlier`.
    public func wallTime(since earlier: Self) -> TimeInterval {
        date.timeIntervalSince(earlier.date)
    }

    /// Time the host spent asleep between `earlier` and this instant, never negative.
    public func timeAsleep(since earlier: Self) -> TimeInterval {
        max(0, wallTime(since: earlier) - awakeTime(since: earlier))
    }
}

/// Time source for the fleet watchdog. Injected so deadlines can be tested with a manual clock.
public protocol FleetClock: Sendable {
    var now: Date { get }
    /// Seconds the host has been awake since an arbitrary origin. Unlike ``now`` it does not
    /// advance while the host sleeps.
    var uptime: TimeInterval { get }
    /// Suspends for `duration`. Throws `CancellationError` when the task is cancelled.
    func sleep(for duration: Duration) async throws
}

public extension FleetClock {
    var instant: FleetInstant {
        FleetInstant(date: now, uptime: uptime)
    }
}

public struct SystemFleetClock: FleetClock {
    public init() {}

    public var now: Date {
        Date()
    }

    /// `systemUptime` is the time the system has been awake since it booted; it pauses in sleep.
    public var uptime: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
