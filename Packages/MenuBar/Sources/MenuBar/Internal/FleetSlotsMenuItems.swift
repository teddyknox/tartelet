import SwiftUI
import VirtualMachineDomain

/// One disabled line per fleet slot showing where it is in its cycle, e.g. `base-1: Busy (12m03s)`.
struct FleetSlotsMenuItems: View {
    let slotStatuses: [VirtualMachineFleetSlotStatus]
    let now: Date

    var body: some View {
        ForEach(slotStatuses) { status in
            Button {} label: {
                Text(title(for: status))
            }
            .disabled(true)
        }
    }
}

private extension FleetSlotsMenuItems {
    private func title(for status: VirtualMachineFleetSlotStatus) -> String {
        let elapsed = FleetDurationFormatter.string(from: now.timeIntervalSince(status.stateEnteredAt))
        return "\(status.name): \(status.state.displayName) (\(elapsed))"
    }
}
