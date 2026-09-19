import Foundation
import SSHDomain

public protocol GuestRunnerIdentityReader {
    func runnerID(of virtualMachine: VirtualMachine) async throws -> Int?
}

/// Bootstrap publishes a copy of .runner only after this guest's config.sh succeeds.
public struct SSHGuestRunnerIdentityReader<Client: SSHClient>: GuestRunnerIdentityReader {
    private struct Identity: Decodable { let agentId: Int }

    private let sshClient: VirtualMachineSSHClient<Client>

    public init(sshClient: VirtualMachineSSHClient<Client>) {
        self.sshClient = sshClient
    }

    public func runnerID(of virtualMachine: VirtualMachine) async throws -> Int? {
        let connection = try await sshClient.openConnection(to: virtualMachine)
        let closer = SSHConnectionCloser(connection)
        do {
            let output = try await withTaskCancellationHandler {
                try await connection.executeCommandReturningOutput(
                    "if test -f ~/.tartelet-runner-identity; then cat ~/.tartelet-runner-identity; fi"
                )
            } onCancel: { closer.begin() }
            await closer.close()
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let identity = try JSONDecoder().decode(Identity.self, from: Data(output.utf8))
            guard identity.agentId > 0 else { throw CocoaError(.coderInvalidValue) }
            return identity.agentId
        } catch {
            await closer.close()
            throw error
        }
    }
}
