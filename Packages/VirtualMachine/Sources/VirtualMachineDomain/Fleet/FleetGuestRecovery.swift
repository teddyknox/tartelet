import Foundation
import LoggingDomain

/// Diagnostics, bounded registration release, then the forced stop, in that order.
struct FleetGuestRecovery {
    let name: String
    let runnerName: String
    let registry: GitHubActionsRunnerRegistry
    let identityReader: GuestRunnerIdentityReader
    let guestLogReader: VirtualMachineGuestLogReader?
    let clock: FleetClock
    let logger: Logger
    let deregistrationTimeout: Duration

    private func releaseRegistration(_ virtualMachine: VirtualMachine, guestID: Int?, observedID: Int?) async {
        let reader = identityReader
        do {
            let releasedID = try await withTimeout(deregistrationTimeout) {
                // Prefer this guest; fall back to the observed name when bootstrap never reported an id.
                var id = guestID
                if id == nil { id = try? await reader.runnerID(of: virtualMachine) }
                if id == nil { id = observedID }
                if id == nil { id = try await registry.status(ofRunnerNamed: self.runnerName).id }
                if let id {
                    try Task.checkCancellation()
                    try await registry.deregisterRunner(id: id)
                }
                return id
            }
            if let releasedID {
                log("deregistration via GitHub API succeeded for runner id \(releasedID); proceeding to forced stop")
            } else {
                log("deregistration via GitHub API: no registration found; proceeding to forced stop")
            }
        } catch is TimeoutError {
            log(
                "deregistration via GitHub API timed out after \(format(deregistrationTimeout));"
                + " falling through to forced stop"
            )
        } catch {
            log("deregistration via GitHub API failed: \(error.localizedDescription); falling through to forced stop")
        }
    }

    func stop(_ virtualMachine: VirtualMachine, guestID: Int?, observedID: Int?) async {
        let recoveryStartedAt = clock.now
        if let guestLogReader {
            do {
                let guestLog = try await withTimeout(VirtualMachineFleetSlot.guestLogTimeout) {
                    try await guestLogReader.readGuestLog(of: virtualMachine)
                }
                logger.info("[slot \(name)] guest diagnostics before the forced stop:\n\(guestLog)")
            } catch {
                log("could not read the guest log before the forced stop: \(error.localizedDescription)")
            }
        }
        await releaseRegistration(virtualMachine, guestID: guestID, observedID: observedID)
        log("forcing the virtual machine to stop")
        await virtualMachine.forceStop()
        log("forced stop finished after \(format(clock.now.timeIntervalSince(recoveryStartedAt)))")
    }

    private func log(_ message: String) {
        logger.info("[slot \(name)] \(message)")
    }

    private func format(_ duration: Duration) -> String {
        FleetDurationFormatter.string(from: duration)
    }

    private func format(_ interval: TimeInterval) -> String {
        FleetDurationFormatter.string(from: interval)
    }
}
