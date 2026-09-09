import Foundation
import LoggingDomain

/// The actor owns polling-failure logging state; the detached timeout operation captures only
/// the registry and runner name. A late response cannot mutate that state after cancellation.
actor FleetRunnerObserver {
    private let registry: GitHubActionsRunnerRegistry
    private let runnerName: String
    private let slotName: String
    private let clock: FleetClock
    private let logger: Logger
    private var lastFailureLogAt: Date?

    var isAvailable: Bool { lastFailureLogAt == nil }

    init(
        registry: GitHubActionsRunnerRegistry,
        runnerName: String,
        slotName: String,
        clock: FleetClock,
        logger: Logger
    ) {
        self.registry = registry
        self.runnerName = runnerName
        self.slotName = slotName
        self.clock = clock
        self.logger = logger
    }

    func read() async -> GitHubActionsRunnerStatus? {
        let registry = self.registry
        let name = runnerName
        do {
            let status = try await withTimeout(VirtualMachineFleetSlot.observationTimeout) {
                try await registry.status(ofRunnerNamed: name)
            }
            if lastFailureLogAt != nil {
                logger.info("[slot \(slotName)] runner list is available again")
                lastFailureLogAt = nil
            }
            return status
        } catch {
            guard !Task.isCancelled else {
                return nil
            }
            if lastFailureLogAt.map({ clock.now.timeIntervalSince($0) >= 300 }) ?? true {
                logger.info(
                    "[slot \(slotName)] could not read the runner list: \(error.localizedDescription);"
                    + " new cycles await an identity baseline; no registration observation recorded;"
                    + " host deadlines still apply"
                )
                lastFailureLogAt = clock.now
            }
            return nil
        }
    }
}
