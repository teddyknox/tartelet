/// Keeps the host awake while the fleet runs.
///
/// Idle-sleep assertions are not enough: once a host has slept (a closed lid), it only dark-wakes
/// for seconds at a time, and a guest that takes a job in that window loses it when the host sleeps
/// again. A `PreventSystemSleep` assertion holds the host in that wake for as long as it is held.
/// Nothing but `pmset disablesleep 1` prevents the lid-close sleep itself.
public protocol HostSleepPrevention: Sendable {
    /// Begins preventing system sleep for `reason`. Idempotent until ``end()``.
    func begin(reason: String)
    /// Ends the prevention begun by ``begin(reason:)``. Idempotent.
    func end()
}

public struct NoHostSleepPrevention: HostSleepPrevention {
    public init() {}

    public func begin(reason: String) {}

    public func end() {}
}
