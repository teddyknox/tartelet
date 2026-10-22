import Foundation
import IOKit.pwr_mgt
import LoggingDomain
import VirtualMachineDomain

/// Holds a `PreventSystemSleep` power assertion while the fleet runs.
///
/// On AC power the assertion prevents idle and maintenance sleep and keeps a host that has
/// dark-woken awake for as long as it is held, so a guest that takes a job during that wake keeps
/// it. It does not prevent lid-close sleep (`pmset disablesleep 1` does) and is ignored on battery.
public final class IOKitHostSleepPrevention: HostSleepPrevention, @unchecked Sendable {
    private let logger: Logger
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0
    private var isHeld = false

    public init(logger: Logger) {
        self.logger = logger
    }

    public func begin(reason: String) {
        lock.withLock {
            guard !isHeld else {
                return
            }
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            guard result == kIOReturnSuccess else {
                logger.error(
                    "could not create the PreventSystemSleep power assertion (IOReturn \(result));"
                    + " the host may sleep while guests are running"
                )
                return
            }
            assertionID = id
            isHeld = true
            logger.info("holding a PreventSystemSleep power assertion: \(reason)")
        }
    }

    public func end() {
        lock.withLock {
            guard isHeld else {
                return
            }
            IOPMAssertionRelease(assertionID)
            isHeld = false
            logger.info("released the PreventSystemSleep power assertion")
        }
    }
}
