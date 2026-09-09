import Foundation
import SSHDomain

/// Fetches `~/start-runner.log` and a process snapshot from a guest over SSH.
///
/// Used by the fleet watchdog right before it force-stops a wedged guest, so the guest-side cause
/// (a lingering `xcodebuild`, a runner that never registered, a failed `config.sh`) ends up in the
/// host log. Every step is bounded by `timeout`.
public struct SSHVirtualMachineGuestLogReader<SSHClientType: SSHClient>: VirtualMachineGuestLogReader {
    private let sshClient: VirtualMachineSSHClient<SSHClientType>
    private let timeout: Duration
    private let maximumLines: Int

    public init(
        sshClient: VirtualMachineSSHClient<SSHClientType>,
        timeout: Duration = .seconds(30),
        maximumLines: Int = 200
    ) {
        self.sshClient = sshClient
        self.timeout = timeout
        self.maximumLines = maximumLines
    }

    public func readGuestLog(of virtualMachine: VirtualMachine) async throws -> String {
        let maximumLines = self.maximumLines
        let sshClient = self.sshClient
        return try await withTimeout(timeout) {
            let connection = try await sshClient.openConnection(to: virtualMachine)
            let closer = SSHConnectionCloser(connection)
            do {
                let output = try await withTaskCancellationHandler {
                    try await connection.executeCommandReturningOutput("""
echo '--- ~/start-runner.log (last \(maximumLines) lines) ---'
tail -n \(maximumLines) ~/start-runner.log 2>&1
echo '--- processes by CPU ---'
ps -axo pid,ppid,%cpu,etime,command -r 2>&1 | head -n 40
""")
                } onCancel: { closer.begin() }
                await closer.close()
                return output
            } catch {
                await closer.close()
                throw error
            }
        }
    }
}
