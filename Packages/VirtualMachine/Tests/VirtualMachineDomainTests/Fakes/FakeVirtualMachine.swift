import Foundation
import VirtualMachineDomain

/// Records what the fleet does to its machines, across the base machine and every clone.
final class FakeVirtualMachineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var recordedClones: [FakeVirtualMachine] = []

    var events: [String] {
        lock.withLock { recordedEvents }
    }

    var clones: [FakeVirtualMachine] {
        lock.withLock { recordedClones }
    }

    func record(_ event: String) {
        lock.withLock { recordedEvents.append(event) }
    }

    func add(_ clone: FakeVirtualMachine) {
        lock.withLock { recordedClones.append(clone) }
    }
}

struct FakeGuestKilled: Error {}

final class FakeVirtualMachine: VirtualMachine, @unchecked Sendable {
    let name: String
    let canStart = true
    let recorder: FakeVirtualMachineRecorder

    /// Error to throw from `start(observer:)` right away, e.g. a `tart run` that fails to launch.
    var startError: Error?
    var cloneError: Error?
    var deleteError: Error?
    /// Whether `forceStop()` makes `start(observer:)` return, as killing `tart run` does.
    var forceStopEndsStart = true

    private let lock = NSLock()
    private var observer: VirtualMachineStartObserver?
    private var exitContinuation: CheckedContinuation<Result<Void, Error>, Never>?
    private var pendingExit: Result<Void, Error>?
    private var isStarted = false

    init(name: String, recorder: FakeVirtualMachineRecorder) {
        self.name = name
        self.recorder = recorder
    }

    var hasStarted: Bool {
        lock.withLock { isStarted }
    }

    func start(observer: VirtualMachineStartObserver?) async throws {
        recorder.record("start \(name)")
        if let startError {
            throw startError
        }
        lock.withLock {
            self.observer = observer
            isStarted = true
        }
        let result: Result<Void, Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let pendingExit {
                    self.pendingExit = nil
                    lock.unlock()
                    continuation.resume(returning: pendingExit)
                    return
                }
                exitContinuation = continuation
                lock.unlock()
            }
        } onCancel: {
            // Like tart on SIGINT: the machine stops and `tart run` returns.
            exitGuest(with: .failure(CancellationError()))
        }
        try result.get()
    }

    /// Simulates the SSH bootstrap completing inside the guest.
    func bootstrap() {
        let observer = lock.withLock { self.observer }
        observer?.virtualMachineDidBootstrap(self)
    }

    /// Simulates the guest powering off (`tart run` returning).
    func exitGuest(with result: Result<Void, Error> = .success(())) {
        lock.lock()
        guard let continuation = exitContinuation else {
            if isStarted {
                pendingExit = result
            }
            lock.unlock()
            return
        }
        exitContinuation = nil
        lock.unlock()
        continuation.resume(returning: result)
    }

    func clone(named newName: String) async throws -> VirtualMachine {
        recorder.record("clone \(newName)")
        if let cloneError {
            throw cloneError
        }
        let clone = FakeVirtualMachine(name: newName, recorder: recorder)
        recorder.add(clone)
        return clone
    }

    func delete() async throws {
        recorder.record("delete \(name)")
        if let deleteError {
            throw deleteError
        }
    }

    func getIPAddress() async throws -> String {
        "192.0.2.1"
    }

    func forceStop() async {
        recorder.record("forceStop \(name)")
        if forceStopEndsStart {
            exitGuest(with: .failure(FakeGuestKilled()))
        }
    }
}
