import Foundation
import LoggingDomain
import Observation

@Observable
@MainActor
public final class VirtualMachineFleet {
    public private(set) var isStarted = false
    public private(set) var isStopping = false
    /// Live status of every slot, in slot order. Empty while the fleet is not running.
    public private(set) var slotStatuses: [VirtualMachineFleetSlotStatus] = []

    private let logger: Logger
    private let baseVirtualMachine: VirtualMachine
    private let runnerRegistry: GitHubActionsRunnerRegistry
    private let runnerConfiguration: GitHubActionsRunnerConfiguration
    private let identityReader: GuestRunnerIdentityReader
    private let guestLogReader: VirtualMachineGuestLogReader?
    private let policy: FleetSlotPolicy
    private let clock: FleetClock
    private var isTerminating = false
    @ObservationIgnored
    private var activeTasks: [String: (id: UUID, task: Task<(), Never>)] = [:]

    public init(
        logger: Logger,
        baseVirtualMachine: VirtualMachine,
        runnerRegistry: GitHubActionsRunnerRegistry,
        runnerConfiguration: GitHubActionsRunnerConfiguration,
        identityReader: GuestRunnerIdentityReader,
        guestLogReader: VirtualMachineGuestLogReader? = nil,
        policy: FleetSlotPolicy = .default,
        clock: FleetClock = SystemFleetClock()
    ) {
        self.logger = logger
        self.baseVirtualMachine = baseVirtualMachine
        self.runnerRegistry = runnerRegistry
        self.runnerConfiguration = runnerConfiguration
        self.identityReader = identityReader
        self.guestLogReader = guestLogReader
        self.policy = policy
        self.clock = clock
    }

    public func start(numberOfMachines: Int) {
        guard !isStarted, !isTerminating, numberOfMachines > 0 else {
            return
        }
        guard baseVirtualMachine.canStart else {
            return
        }
        isStarted = true
        isStopping = false
        slotStatuses = []
        for index in 0 ..< numberOfMachines {
            let name = baseVirtualMachine.name + "-\(index + 1)"
            startSlot(named: name)
        }
    }

    public func stopImmediately() {
        isStopping = !activeTasks.isEmpty
        for (_, entry) in activeTasks {
            entry.task.cancel()
        }
        if activeTasks.isEmpty {
            isStarted = false
            slotStatuses = []
        }
    }

    /// Keeps the fleet unavailable for restart until every old slot has finished teardown.
    public func stopAndWait(forTermination: Bool = false) async {
        if forTermination { isTerminating = true }
        let tasks = activeTasks.values.map(\.task)
        stopImmediately()
        for task in tasks { await task.value }
    }

    public func stop() {
        guard isStarted else {
            return
        }
        isStopping = true
    }
}

private extension VirtualMachineFleet {
    private func startSlot(named name: String) {
        let runID = UUID()
        let slot = VirtualMachineFleetSlot(
            name: name,
            runnerName: GitHubActionsRunnerName.make(
                virtualMachineName: name,
                configuredRunnerName: runnerConfiguration.runnerName
            ),
            baseVirtualMachine: baseVirtualMachine,
            runnerRegistry: runnerRegistry,
            identityReader: identityReader,
            guestLogReader: guestLogReader,
            policy: policy,
            clock: clock,
            logger: logger
        ) { [weak self] status in
            Task { @MainActor in
                self?.update(status, runID: runID)
            }
        }
        slotStatuses.append(slot.status)
        let task = Task {
            await slot.run { @MainActor [weak self] in
                self?.isStopping ?? true
            }
            await MainActor.run { [weak self] in
                self?.slotDidFinish(named: name, runID: runID)
            }
        }
        activeTasks[name] = (runID, task)
    }

    @MainActor
    private func update(_ status: VirtualMachineFleetSlotStatus, runID: UUID) {
        guard activeTasks[status.name]?.id == runID else {
            return
        }
        guard let index = slotStatuses.firstIndex(where: { $0.name == status.name }) else {
            return
        }
        // Updates hop to the main actor individually; never let an older one overwrite a newer one.
        guard slotStatuses[index].revision < status.revision else {
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
