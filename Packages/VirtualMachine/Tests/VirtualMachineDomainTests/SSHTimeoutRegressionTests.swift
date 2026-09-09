import Foundation
import SSHDomain
@testable import VirtualMachineDomain
import XCTest

final class SSHTimeoutRegressionTests: XCTestCase {
    func testCancelledBootstrapReturnsEvenWhenEachSSHStageIgnoresCancellation() async throws {
        for stage in [Stage.ip, .authentication, .handler, .close] {
            let gate = AsyncTestGate()
            let entered = expectation(description: "entered \(stage)")
            let returned = expectation(description: "start returned \(stage)")
            let released = expectation(description: "blocked stage released \(stage)")
            let blocker: () async -> Void = {
                entered.fulfill()
                await gate.wait()
                released.fulfill()
            }
            let connection = ProbeConnection()
            if stage == .close { connection.onClose = blocker }
            let client = ProbeSSHClient(connection: connection, beforeConnect: stage == .authentication ? blocker : {})
            let handler = ProbeHandler(operation: stage == .handler ? blocker : {})
            let ip = ProbeIPReader(operation: stage == .ip ? blocker : {})
            let ssh = VirtualMachineSSHClient(
                logger: SpyLogger(),
                client: client,
                ipAddressReader: ip,
                credentialsStore: ProbeCredentials(),
                connectionHandler: handler
            )
            let guest = FakeVirtualMachine(name: "guest", recorder: FakeVirtualMachineRecorder())
            let observer = ProbeObserver()
            let machine = SSHConnectingVirtualMachine(logger: SpyLogger(), virtualMachine: guest, sshClient: ssh)
            let start = Task {
                _ = try? await machine.start(observer: observer)
                returned.fulfill()
            }
            await fulfillment(of: [entered], timeout: 1)
            start.cancel()
            await fulfillment(of: [returned], timeout: 1)
            gate.open()
            await fulfillment(of: [released], timeout: 1)
            await start.value
            XCTAssertEqual(observer.count, 0, "a late SSH result must not bootstrap a reused slot")
            if stage != .ip {
                let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                while connection.closeCount == 0, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                XCTAssertGreaterThan(connection.closeCount, 0)
            }
        }
    }

    func testBootstrapDeadlineStopsGuestWhileAuthenticationIsWedged() async throws {
        let gate = AsyncTestGate()
        let entered = expectation(description: "authentication")
        let returned = expectation(description: "deadline returned")
        let connection = ProbeConnection()
        let ssh = VirtualMachineSSHClient(
            logger: SpyLogger(),
            client: ProbeSSHClient(connection: connection) {
                entered.fulfill(); await gate.wait()
            },
            ipAddressReader: ProbeIPReader {},
            credentialsStore: ProbeCredentials(),
            connectionHandler: ProbeHandler {}
        )
        let guest = FakeVirtualMachine(name: "guest", recorder: FakeVirtualMachineRecorder())
        let machine = SSHConnectingVirtualMachine(
            logger: SpyLogger(),
            virtualMachine: guest,
            sshClient: ssh,
            bootstrapTimeout: .milliseconds(100)
        )
        let task = Task {
            _ = try? await machine.start(); returned.fulfill()
        }
        await fulfillment(of: [entered, returned], timeout: 1)
        gate.open()
        await task.value
    }

    func testGuestLogTimeoutClosesTransportEvenIfReadNeverReturns() async throws {
        let gate = AsyncTestGate()
        let closed = expectation(description: "transport closed")
        let connection = ProbeConnection()
        connection.onRead = { await gate.wait() }
        connection.onClose = { closed.fulfill() }
        let ssh = VirtualMachineSSHClient(
            logger: SpyLogger(),
            client: ProbeSSHClient(connection: connection),
            ipAddressReader: ProbeIPReader {},
            credentialsStore: ProbeCredentials(),
            connectionHandler: ProbeHandler { XCTFail("diagnostics must not bootstrap") }
        )
        let reader = SSHVirtualMachineGuestLogReader(sshClient: ssh, timeout: .milliseconds(100))
        let guest = FakeVirtualMachine(name: "guest", recorder: FakeVirtualMachineRecorder())
        do { _ = try await reader.readGuestLog(of: guest); XCTFail("timeout") } catch is TimeoutError {}
        await fulfillment(of: [closed], timeout: 1)
        gate.open()
        XCTAssertEqual(connection.closeCount, 1)
    }
}

private enum Stage { case ip, authentication, handler, close }
private struct ProbeSSHClient: SSHClient {
    let connection: ProbeConnection
    var beforeConnect: () async -> Void = {}
    func connect(host: String, username: String, password: String) async throws -> ProbeConnection {
        await beforeConnect()
        return connection
    }
}
private final class ProbeConnection: SSHConnection {
    private let lock = NSLock()
    private var closes = 0
    var onClose: () async -> Void = {}
    var onRead: () async -> Void = {}
    var closeCount: Int { lock.withLock { closes } }
    func executeCommand(_ command: String) async throws {}
    func executeCommandReturningOutput(_ command: String) async throws -> String { await onRead(); return "log" }
    func close() async throws { lock.withLock { closes += 1 }; await onClose() }
}
private struct ProbeIPReader: VirtualMachineIPAddressReader {
    let operation: () async -> Void
    func readIPAddress(of virtualMachine: VirtualMachine) async throws -> String {
        await operation(); return "192.0.2.1"
    }
}
private struct ProbeHandler: VirtualMachineSSHConnectionHandler {
    let operation: () async -> Void
    func didConnect(to virtualMachine: VirtualMachine, through sshConnection: SSHConnection) async throws {
        await operation()
    }
}
private final class ProbeCredentials: VirtualMachineSSHCredentialsStore {
    var username: String? = "test"
    var password: String? = "test"
    func setUsername(_ username: String?) { self.username = username }
    func setPassword(_ password: String?) { self.password = password }
}
private final class ProbeObserver: VirtualMachineStartObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var observations = 0
    var count: Int { lock.withLock { observations } }
    func virtualMachineDidBootstrap(_ virtualMachine: VirtualMachine) { lock.withLock { observations += 1 } }
}
