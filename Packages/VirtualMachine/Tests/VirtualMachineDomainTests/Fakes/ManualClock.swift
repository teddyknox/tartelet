import Foundation
import VirtualMachineDomain

/// A clock the test advances by hand. Sleepers wake when `now` reaches their deadline.
final class ManualClock: FleetClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let wakeAt: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var currentNow: Date
    private var sleepers: [Sleeper] = []
    private var registrations: UInt64 = 0

    var sleepGeneration: UInt64 { lock.withLock { registrations } }

    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        currentNow = now
    }

    var now: Date {
        lock.withLock { currentNow }
    }

    var sleeperCount: Int {
        lock.withLock { sleepers.count }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let wakeAt = currentNow.addingTimeInterval(seconds)
                if wakeAt <= currentNow {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers.append(Sleeper(id: id, wakeAt: wakeAt, continuation: continuation))
                registrations += 1
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let cancelled = sleepers.filter { $0.id == id }
            sleepers.removeAll { $0.id == id }
            lock.unlock()
            for sleeper in cancelled {
                sleeper.continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    func advance(by seconds: TimeInterval) {
        lock.lock()
        currentNow = currentNow.addingTimeInterval(seconds)
        let due = sleepers.filter { $0.wakeAt <= currentNow }
        sleepers.removeAll { $0.wakeAt <= currentNow }
        lock.unlock()
        for sleeper in due.sorted(by: { $0.wakeAt < $1.wakeAt }) {
            sleeper.continuation.resume()
        }
    }

    /// Waits until at least one task is sleeping on this clock, then advances it.
    @discardableResult
    func advanceWhenSleeping(by seconds: TimeInterval, timeout: TimeInterval = 5) async throws -> UInt64 {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            // Readiness and advance are one transaction. A cancellation cannot remove the
            // observed sleeper between a count check and a separate advance call.
            let batch: (UInt64, [Sleeper])? = lock.withLock {
                guard !sleepers.isEmpty else {
                    return nil
                }
                let generation = registrations
                currentNow = currentNow.addingTimeInterval(seconds)
                let due = sleepers.filter { $0.wakeAt <= currentNow }
                sleepers.removeAll { $0.wakeAt <= currentNow }
                return (generation, due)
            }
            if let (generation, due) = batch {
                due.forEach { $0.continuation.resume() }
                return generation
            }
            if Date() > deadline {
                throw ManualClockError.nobodySleeping
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

enum ManualClockError: Error {
    case nobodySleeping
}
