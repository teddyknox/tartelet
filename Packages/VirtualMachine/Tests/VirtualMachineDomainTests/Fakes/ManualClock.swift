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
    func advanceWhenSleeping(by seconds: TimeInterval, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while sleeperCount == 0 {
            if Date() > deadline {
                throw ManualClockError.nobodySleeping
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        advance(by: seconds)
    }
}

enum ManualClockError: Error {
    case nobodySleeping
}
