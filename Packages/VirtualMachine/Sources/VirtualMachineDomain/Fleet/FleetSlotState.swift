/// Where a fleet slot is in its clone → run → delete cycle.
///
/// The happy path is `idle → cloning → booting → bootstrapped → registered → busy → draining →
/// exited → idle`. `recovering` is entered when the host watchdog trips a deadline and is
/// forcing the guest off; it always leads to `exited` and a fresh clone.
public enum FleetSlotState: String, CaseIterable, Equatable, Sendable {
    /// No virtual machine exists for the slot.
    case idle
    /// `tart clone` is running.
    case cloning
    /// `tart run` has started; waiting for the guest to come up and finish its SSH bootstrap.
    case booting
    /// The runner setup script has been launched in the guest; waiting for GitHub to list the runner online.
    case bootstrapped
    /// GitHub lists the runner online and idle.
    case registered
    /// GitHub lists the runner online and running a job.
    case busy
    /// The ephemeral runner has finished (unregistered or gone offline); waiting for the guest to power off.
    case draining
    /// A deadline tripped; the host is capturing the guest log and forcing the guest off.
    case recovering
    /// `tart run` has returned; the clone is being deleted.
    case exited

    public var displayName: String {
        switch self {
        case .idle:
            "Idle"
        case .cloning:
            "Cloning"
        case .booting:
            "Booting"
        case .bootstrapped:
            "Bootstrapped"
        case .registered:
            "Registered"
        case .busy:
            "Busy"
        case .draining:
            "Draining"
        case .recovering:
            "Recovering"
        case .exited:
            "Exited"
        }
    }
}
