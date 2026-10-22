import Foundation

/// Why a guest is being stopped, and whether GitHub may overrule it.
struct FleetGuestStopRequest: Sendable {
    let reason: String
    /// A watchdog deadline can be wrong about a guest GitHub still lists as running a job; such a
    /// guest is kept. Stop, Quit and a failed bootstrap never keep it.
    let keepsBusyGuest: Bool

    static func deadline(_ reason: String) -> Self {
        Self(reason: reason, keepsBusyGuest: true)
    }

    static func termination(_ reason: String) -> Self {
        Self(reason: reason, keepsBusyGuest: false)
    }
}

/// One committed cleanup per clone, unaffected by cancellation of any caller.
///
/// A cleanup that kept a busy guest commits nothing: the next request runs a fresh one, and a
/// termination request that joined it runs again without the busy exemption.
actor FleetGuestStopper {
    private var task: Task<FleetGuestRecovery.Outcome, Never>?
    private let operation: @Sendable (FleetGuestStopRequest) async -> FleetGuestRecovery.Outcome

    init(operation: @escaping @Sendable (FleetGuestStopRequest) async -> FleetGuestRecovery.Outcome) {
        self.operation = operation
    }

    /// The detached start keeps parent cancellation from reaching tart before release completes.
    func run(_ virtualMachine: VirtualMachine, observer: VirtualMachineStartObserver) async -> Result<Void, Error> {
        let start = Task.detached { try await virtualMachine.start(observer: observer) }
        do {
            try await withTaskCancellationHandler {
                try await start.value
            } onCancel: {
                Task {
                    await self.stop(.termination("slot cancelled (Stop/Quit); releasing registration before stopping"))
                    start.cancel()
                }
            }
            if Task.isCancelled { await stop(.termination("slot cancelled (Stop/Quit)")) }
            return .success(())
        } catch {
            if Task.isCancelled { await stop(.termination("slot cancelled (Stop/Quit)")) }
            return .failure(error)
        }
    }

    @discardableResult
    func stop(_ request: FleetGuestStopRequest) async -> FleetGuestRecovery.Outcome {
        while true {
            let current: Task<FleetGuestRecovery.Outcome, Never>
            if let task {
                current = task
            } else {
                let operation = self.operation
                current = Task.detached { await operation(request) }
                task = current
            }
            let outcome = await current.value
            guard case .keptBusyGuest = outcome else {
                return outcome
            }
            if task == current {
                task = nil
            }
            if request.keepsBusyGuest {
                return outcome
            }
        }
    }
}
