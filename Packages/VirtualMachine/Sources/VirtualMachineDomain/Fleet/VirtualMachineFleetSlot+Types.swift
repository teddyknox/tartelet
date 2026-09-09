import Foundation

extension VirtualMachineFleetSlot {
    enum RunEvent {
        case exited(Result<Void, Error>)
        case watchdogFinished(tripped: Bool)
        case forcedExitGraceElapsed
    }

    public enum CycleOutcome: Equatable {
        /// The guest powered off on its own.
        case completed
        /// A deadline tripped and the guest was forced off.
        case forcedStop
        /// Cloning, starting or deleting failed; the fleet backs off before trying again.
        case failed
        /// The fleet was stopped while the cycle was running.
        case cancelled
    }

    public enum DeadlineTrip: Equatable, CustomStringConvertible {
        case bootTimeout
        case registrationTimeout
        case shutdownTimeout
        case lifetimeExceeded

        public var description: String {
            switch self {
            case .bootTimeout:
                "boot"
            case .registrationTimeout:
                "registration"
            case .shutdownTimeout:
                "shutdown"
            case .lifetimeExceeded:
                "lifetime"
            }
        }
    }

    /// How long to wait for `tart run` to return after a forced stop before cancelling it outright.
    static let forcedExitGracePeriod: Duration = .seconds(60)
    /// Bound on reading the guest log before a forced stop.
    static let guestLogTimeout: Duration = .seconds(45)
    /// Bound on one runner-list poll.
    static let observationTimeout: Duration = .seconds(60)
}

extension VirtualMachineFleetSlot {
    func format(_ duration: Duration) -> String {
        FleetDurationFormatter.string(from: duration)
    }

    func format(_ interval: TimeInterval) -> String {
        FleetDurationFormatter.string(from: interval)
    }
}
