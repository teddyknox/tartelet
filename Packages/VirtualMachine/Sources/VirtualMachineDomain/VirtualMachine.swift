import Foundation

/// Receives lifecycle milestones while a virtual machine started with
/// ``VirtualMachine/start(observer:)`` is running.
public protocol VirtualMachineStartObserver: AnyObject, Sendable {
    /// The guest is reachable and its post-boot setup over SSH (the runner bootstrap) has completed.
    func virtualMachineDidBootstrap(_ virtualMachine: VirtualMachine)
}

public protocol VirtualMachine {
    var name: String { get }
    var canStart: Bool { get }
    /// Starts the virtual machine and returns once it has powered off.
    func start(observer: VirtualMachineStartObserver?) async throws
    func clone(named newName: String) async throws -> VirtualMachine
    /// Deletes the virtual machine and leaves no trace of it on disk.
    func delete() async throws
    func getIPAddress() async throws -> String
    /// Forcibly stops a virtual machine started with ``start(observer:)``.
    ///
    /// Escalates from a graceful stop request to killing the process and returns once the machine
    /// has stopped or every option has been exhausted. Never waits unboundedly and is not
    /// interrupted by task cancellation, so a fleet being torn down can still rely on it.
    func forceStop() async
}

public extension VirtualMachine {
    func start() async throws {
        try await start(observer: nil)
    }
}
