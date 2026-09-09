import Foundation

/// Bridges a virtual machine's bootstrap milestone back to its slot, ignoring late reports from
/// an earlier cycle.
final class FleetSlotCycleObserver: VirtualMachineStartObserver, @unchecked Sendable {
    private weak var slot: VirtualMachineFleetSlot?
    private let cycleID: UUID

    init(slot: VirtualMachineFleetSlot, cycleID: UUID) {
        self.slot = slot
        self.cycleID = cycleID
    }

    func virtualMachineDidBootstrap(_ virtualMachine: VirtualMachine) {
        slot?.didBootstrap(cycleID: cycleID)
    }
}
