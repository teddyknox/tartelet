/// Reads diagnostics from inside a running guest, for the host log.
public protocol VirtualMachineGuestLogReader {
    /// Returns the tail of the guest's runner log and a snapshot of its processes.
    ///
    /// Best effort: implementations must give up within a bounded time.
    func readGuestLog(of virtualMachine: VirtualMachine) async throws -> String
}
