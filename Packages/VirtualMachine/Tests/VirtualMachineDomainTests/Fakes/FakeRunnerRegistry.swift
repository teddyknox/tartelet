import Foundation
import LoggingDomain
import VirtualMachineDomain

struct FakeAPIError: Error {}

final class FakeRunnerRegistry: GitHubActionsRunnerRegistry, @unchecked Sendable {
    private let lock = NSLock()
    private var currentResult: Result<GitHubActionsRunnerStatus, Error> = .success(.unregistered)
    private var queriedNames: [String] = []
    var recorder: FakeVirtualMachineRecorder?
    var deregistrationError: Error?
    var beforeDeregister: (() async -> Void)?
    var beforeResult: (() async -> Void)?

    var result: Result<GitHubActionsRunnerStatus, Error> {
        get { lock.withLock { currentResult } }
        set { lock.withLock { currentResult = newValue } }
    }

    var status: GitHubActionsRunnerStatus {
        get {
            switch result {
            case let .success(status):
                return status
            case .failure:
                return .unregistered
            }
        }
        set { result = .success(newValue) }
    }

    var queries: [String] {
        lock.withLock { queriedNames }
    }

    func deregisterRunner(id: Int) async throws {
        recorder?.record("deregister \(id)")
        await beforeDeregister?()
        if let deregistrationError { throw deregistrationError }
        status = .unregistered
    }

    func status(ofRunnerNamed name: String) async throws -> GitHubActionsRunnerStatus {
        let result = lock.withLock {
            queriedNames.append(name)
            return currentResult
        }
        await beforeResult?()
        return try result.get()
    }
}

final class FakeGuestLogReader: VirtualMachineGuestLogReader, @unchecked Sendable {
    private let lock = NSLock()
    private var readNames: [String] = []
    var log = "[start-runner] fake guest log"
    var error: Error?

    var reads: [String] {
        lock.withLock { readNames }
    }

    func readGuestLog(of virtualMachine: VirtualMachine) async throws -> String {
        lock.withLock { readNames.append(virtualMachine.name) }
        if let error {
            throw error
        }
        return log
    }
}

final class SpyLogger: LoggingDomain.Logger, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var messages: [String] {
        lock.withLock { lines }
    }

    func info(_ message: String) {
        lock.withLock { lines.append("INFO: \(message)") }
    }

    func error(_ message: String) {
        lock.withLock { lines.append("ERROR: \(message)") }
    }
}

final class FakeGuestIdentityReader: GuestRunnerIdentityReader, @unchecked Sendable {
    var id: Int? = 1
    var error: Error?
    func runnerID(of virtualMachine: VirtualMachine) async throws -> Int? {
        if let error { throw error }
        return id
    }
}
