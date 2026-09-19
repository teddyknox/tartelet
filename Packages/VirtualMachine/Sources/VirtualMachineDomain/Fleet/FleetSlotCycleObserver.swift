import Foundation

/// Bridges a virtual machine's bootstrap milestone back to its slot, ignoring late reports from
/// an earlier cycle.
final class FleetSlotCycleObserver: VirtualMachineStartObserver, @unchecked Sendable {
    private weak var slot: VirtualMachineFleetSlot?
    private let cycleID: UUID
    private let stopper: FleetGuestStopper

    init(slot: VirtualMachineFleetSlot, cycleID: UUID, stopper: FleetGuestStopper) {
        self.slot = slot
        self.cycleID = cycleID
        self.stopper = stopper
    }

    func virtualMachineWillStop(_ virtualMachine: VirtualMachine) async {
        await stopper.stop(reason: "bootstrap failed; releasing registration before stopping")
    }

    func virtualMachineDidBootstrap(_ virtualMachine: VirtualMachine) {
        slot?.didBootstrap(cycleID: cycleID)
    }
}
