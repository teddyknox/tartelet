import AppKit
import Foundation
import LoggingDomain
import VirtualMachineDomain

/// Writes host sleep and wake into the fleet log, so a slot transition or recovery that follows a
/// sleep gap can be read for what it is.
///
/// AppKit posts these notifications for full sleeps and wakes only; a dark wake (Power Nap, TCP
/// keep-alive) is invisible here and shows up only as awake time standing still in the slot logs.
@MainActor
final class HostSleepObserver {
    private let logger: Logger
    private var observers: [NSObjectProtocol] = []
    private var sleptAt: FleetInstant?

    init(logger: Logger) {
        self.logger = logger
    }

    func start() {
        guard observers.isEmpty else {
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hostWillSleep() }
            }
        )
        observers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hostDidWake() }
            }
        )
    }

    private func hostWillSleep() {
        sleptAt = SystemFleetClock().instant
        logger.info("host is going to sleep; guests pause and slot deadlines stop counting until it wakes")
    }

    private func hostDidWake() {
        let now = SystemFleetClock().instant
        guard let sleptAt else {
            logger.info("host woke")
            return
        }
        self.sleptAt = nil
        logger.info(
            "host woke after \(FleetDurationFormatter.string(from: now.timeAsleep(since: sleptAt))) asleep;"
            + " a guest that was running a job has lost it unless GitHub still lists it busy"
        )
    }
}
