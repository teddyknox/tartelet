import Foundation

/// One committed cleanup per clone, unaffected by cancellation of any caller.
actor FleetGuestStopper {
    private var task: Task<Void, Never>?
    private let operation: @Sendable (String) async -> Void

    init(operation: @escaping @Sendable (String) async -> Void) {
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
                    await self.stop(reason: "slot cancelled (Stop/Quit); releasing registration before stopping")
                    start.cancel()
                }
            }
            if Task.isCancelled { await stop(reason: "slot cancelled (Stop/Quit)") }
            return .success(())
        } catch {
            if Task.isCancelled { await stop(reason: "slot cancelled (Stop/Quit)") }
            return .failure(error)
        }
    }

    func stop(reason: String) async {
        if task == nil {
            let operation = self.operation
            task = Task.detached { await operation(reason) }
        }
        await task?.value
    }
}
