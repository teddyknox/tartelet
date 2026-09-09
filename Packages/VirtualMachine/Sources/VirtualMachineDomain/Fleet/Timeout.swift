import Foundation

public struct TimeoutError: LocalizedError, Equatable {
    public let duration: Duration

    public init(duration: Duration) {
        self.duration = duration
    }

    public var errorDescription: String? {
        "Timed out after \(FleetDurationFormatter.string(from: duration))"
    }
}

/// Runs `operation` and throws ``TimeoutError`` if it has not finished within `duration`.
///
/// The bound is real time and holds even when the operation ignores cancellation: on timeout the
/// operation is cancelled and left to finish on its own, and the caller continues right away. It
/// exists so that an await on a possibly wedged guest cannot hang a slot. Host commands must
/// instead use ShellProcess's bounded termination, so they cannot mutate a reused VM name later.
/// Cancelling the calling task cancels the operation and rethrows the cancellation.
public func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try Task.checkCancellation()
    let outcome = TimeoutOutcome<T>()
    let operationTask = Task.detached {
        do {
            try Task.checkCancellation()
            outcome.resolve(.success(try await operation()))
        } catch {
            outcome.resolve(.failure(error))
        }
    }
    let timerTask = Task.detached {
        try await Task.sleep(for: duration)
        outcome.resolve(.failure(TimeoutError(duration: duration)))
        operationTask.cancel()
    }
    defer {
        timerTask.cancel()
    }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            outcome.await(continuation)
        }
    } onCancel: {
        outcome.resolve(.failure(CancellationError()))
        operationTask.cancel()
    }
}

/// Delivers exactly one result to exactly one continuation, from whichever side gets there first.
private final class TimeoutOutcome<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?

    func resolve(_ newResult: Result<T, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = newResult
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume(with: newResult)
    }

    func `await`(_ newContinuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            newContinuation.resume(with: result)
            return
        }
        continuation = newContinuation
        lock.unlock()
    }
}
