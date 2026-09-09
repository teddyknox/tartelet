import Foundation

/// A snapshot of one slot for the UI and logs.
public struct VirtualMachineFleetSlotStatus: Equatable, Identifiable, Sendable {
    public var id: String {
        name
    }
    /// Name of the slot's virtual machine clone, e.g. `base-1`.
    public let name: String
    /// Name the slot's runner registers with on GitHub.
    public let runnerName: String
    public let state: FleetSlotState
    /// When `state` was entered.
    public let stateEnteredAt: Date
    /// When the current clone → delete cycle started; `nil` while idle.
    public let cycleStartedAt: Date?
    public let revision: UInt64

    public init(
        name: String,
        runnerName: String,
        state: FleetSlotState,
        stateEnteredAt: Date,
        cycleStartedAt: Date?,
        revision: UInt64 = 0
    ) {
        self.name = name
        self.runnerName = runnerName
        self.state = state
        self.stateEnteredAt = stateEnteredAt
        self.cycleStartedAt = cycleStartedAt
        self.revision = revision
    }
}
