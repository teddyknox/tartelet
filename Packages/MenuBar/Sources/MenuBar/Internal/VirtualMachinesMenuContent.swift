import Foundation
import SettingsDomain
import SwiftUI
import VirtualMachineDomain

struct VirtualMachinesMenuContent: View {
    enum Action {
        case startFleet
        case stopFleet
        case startEditor
    }

    let configurationState: ConfigurationState
    let virtualMachineState: VirtualMachineState
    let slotStatuses: [VirtualMachineFleetSlotStatus]
    let onSelect: (Action) -> Void

    var body: some View {
        FleetMenuBarItem(
            configurationState: configurationState,
            virtualMachineState: virtualMachineState,
            startFleet: {
                onSelect(.startFleet)
            },
            stopFleet: {
                onSelect(.stopFleet)
            }
        )
        if !slotStatuses.isEmpty {
            FleetSlotsMenuItems(slotStatuses: slotStatuses, now: Date())
        }
        Divider()
        EditorMenuBarItem(
            configurationState: configurationState,
            virtualMachineState: virtualMachineState
        ) {
            onSelect(.startEditor)
        }
    }
}
