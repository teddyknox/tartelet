import Foundation
import LoggingDomain
import Observation

@Observable
public final class VirtualMachineFleet {
    public private(set) var isStarted = false
    public private(set) var isStopping = false
    /// Live status of every slot, in slot order. Empty while the fleet is not running.
    public private(set) var slotStatuses: [VirtualMachineFleetSlotStatus] = []

    private let logger: Logger
    private let baseVirtualMachine: VirtualMachine
    private let runnerRegistry: GitHubActionsRunnerRegistry
    private let runnerConfiguration: GitHubActionsRunnerConfiguration
    private let guestLogReader: VirtualMachineGuestLogReader?
    private let policy: FleetSlotPolicy
    private let clock: FleetClock
    @ObservationIgnored
    private var activeTasks: [String: (id: UUID, task: Task<(), Never>)] = [:]

    public init(
        logger: Logger,
        baseVirtualMachine: VirtualMachine,
        runnerRegistry: GitHubActionsRunnerRegistry,
        runnerConfiguration: GitHubActionsRunnerConfiguration,
        guestLogReader: VirtualMachineGuestLogReader? = nil,
        policy: FleetSlotPolicy = .default,
        clock: FleetClock = SystemFleetClock()
    ) {
        self.logger = logger
        self.baseVirtualMachine = baseVirtualMachine
        self.runnerRegistry = runnerRegistry
        self.runnerConfiguration = runnerConfiguration
        self.guestLogReader = guestLogReader
        self.policy = policy
        self.clock = clock
    }

    public func start(numberOfMachines: Int) {
        guard !isStarted else {
            return
        }
        guard baseVirtualMachine.canStart else {
            return
        }
        isStarted = true
        slotStatuses = []
        for index in 0 ..< numberOfMachines {
            let name = baseVirtualMachine.name + "-\(index + 1)"
            startSlot(named: name)
        }
    }

    public func stopImmediately() {
        isStarted = false
        isStopping = false
        for (_, entry) in activeTasks {
            entry.task.cancel()
        }
        activeTasks = [:]
        slotStatuses = []
    }

    public func stop() {
        isStopping = true
    }
}

private extension VirtualMachineFleet {
    private func startSlot(named name: String) {
        let slot = VirtualMachineFleetSlot(
            name: name,
            runnerName: GitHubActionsRunnerName.make(
                virtualMachineName: name,
                configuredRunnerName: runnerConfiguration.runnerName
            ),
            baseVirtualMachine: baseVirtualMachine,
            runnerRegistry: runnerRegistry,
            guestLogReader: guestLogReader,
            policy: policy,
            clock: clock,
            logger: logger
        ) { [weak self] status in
            Task { @MainActor in
                self?.update(status)
            }
        }
        slotStatuses.append(slot.status)
        let runID = UUID()
        let task = Task {
            await slot.run { [weak self] in
                self?.isStopping ?? true
            }
            await MainActor.run { [weak self] in
                self?.slotDidFinish(named: name, runID: runID)
            }
        }
        activeTasks[name] = (runID, task)
    }

    @MainActor
    private func update(_ status: VirtualMachineFleetSlotStatus) {
        guard let index = slotStatuses.firstIndex(where: { $0.name == status.name }) else {
            return
        }
        // Updates hop to the main actor individually; never let an older one overwrite a newer one.
        guard slotStatuses[index].stateEnteredAt <= status.stateEnteredAt else {
            return
        }
        slotStatuses[index] = status
    }

    @MainActor
    private func slotDidFinish(named name: String, runID: UUID) {
        logger.info("Task running virtual machine named \(name) has finished.")
        guard activeTasks[name]?.id == runID else {
            // The fleet was restarted while the old slot was still winding down.
            return
        }
        activeTasks.removeValue(forKey: name)
        if activeTasks.isEmpty {
            stopImmediately()
        }
    }
}
