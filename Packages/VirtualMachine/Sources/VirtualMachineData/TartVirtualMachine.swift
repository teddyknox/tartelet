import Foundation
import LoggingDomain
import ShellDomain
import VirtualMachineDomain

public enum TartVirtualMachineError: LocalizedError, Equatable {
    case directoryNotRemoved(String)
    case unsafeDirectory(String)
    case unownedDirectory(String)
    case slotInUse(String)
    case releasedLease
    case quarantinedSlot(String)
    case unrelatedDiskHolder(Int32)
    case processNotInspectable(Int32)
    case processStillRunning(Int32)
    case invalidProcessList

    public var errorDescription: String? {
        switch self {
        case let .directoryNotRemoved(path):
            "The virtual machine directory at \(path) could not be removed"
        case let .unsafeDirectory(path):
            "Refusing unsafe VM path \(path)"
        case let .unownedDirectory(path):
            "Refusing to remove \(path): no matching Tartelet ownership marker."
                + " Stop and move or remove the legacy VM manually."
        case let .slotInUse(name):
            "Another Tartelet cycle owns slot \(name)"
        case .releasedLease:
            "The VM lease has been released; begin a new cycle before accessing this slot"
        case let .quarantinedSlot(path):
            "An unreaped command quarantined this slot. Verify that it has exited, then remove \(path) to retry."
        case let .unrelatedDiskHolder(pid):
            "Leaving VM files intact: unrelated process \(pid) holds them open"
        case let .processNotInspectable(pid):
            "Cannot verify the identity of process \(pid); leaving VM files intact"
        case let .processStillRunning(pid):
            "Process \(pid) has not exited after SIGKILL; leaving VM files intact"
        case .invalidProcessList:
            "Host process inspection returned an invalid process list"
        }
    }
}

public final class TartVirtualMachine: VirtualMachine {
    struct StopTiming {
        var interrupt: Duration = .seconds(10)
        var cancellation: Duration = .seconds(15)
        var kill: Duration = .seconds(10)
    }

    public var name: String { vmName }
    public var canStart: Bool { true }
    private let tart: Tart
    private let vmName: String
    private let lease: VirtualMachineLease?
    private let ownership: OwnedVirtualMachineDirectory?
    private let inspector: HostProcessInspecting
    private let timing: StopTiming
    // The process handle crosses the start/cleanup tasks and is always accessed under the lock.
    private let lock = NSLock()
    private var runProcess: ShellProcess?

    public convenience init(tart: Tart, vmName: String) {
        self.init(tart: tart, vmName: vmName, inspector: HostProcessInspector(shell: tart.shell))
    }

    init(
        tart: Tart,
        vmName: String,
        inspector: HostProcessInspecting,
        timing: StopTiming = StopTiming(),
        ownership: OwnedVirtualMachineDirectory? = nil,
        lease: VirtualMachineLease? = nil
    ) {
        self.tart = tart.frozen()
        self.vmName = vmName
        self.inspector = inspector
        self.timing = timing
        self.ownership = ownership
        self.lease = lease
    }

    public func start(observer: VirtualMachineStartObserver?) async throws {
        try Task.checkCancellation()
        try lease?.ensureReady()
        _ = try OwnedVirtualMachineDirectory.checkedURL(tart: tart, name: vmName)
        if let ownership { try ownership.verify(tart: tart) }
        let process = try tart.launchRun(name: vmName)
        lock.withLock { runProcess = process }
        defer { lock.withLock { if !process.isRunning { runProcess = nil } } }
        // No guest lifetime is imposed here (the editor also uses start). Cancellation owns
        // SIGINT -> bounded wait -> SIGKILL -> bounded wait, even if tart never reports an exit.
        _ = try await process.output(interruptGrace: timing.cancellation, killGrace: timing.kill)
    }

    public func clone(named newName: String) async throws -> VirtualMachine {
        let destination = try OwnedVirtualMachineDirectory.checkedURL(tart: tart, name: newName)
        _ = try OwnedVirtualMachineDirectory.checkedURL(tart: tart, name: vmName)
        guard newName != vmName else { throw TartVirtualMachineError.unsafeDirectory(destination.path) }
        let lease = try VirtualMachineLease(tart: tart, name: newName)
        do {
            try await Task.detached { [self] in
                try await ensureAbsent(name: newName)
            }.value
            try Task.checkCancellation()
            // tart clone itself can replace a destination. Give it a unique unpublished name;
            // the operator-visible name is published only after the ownership marker is durable.
            let stageName = ".tartelet-clone-\(UUID().uuidString)"
            let staging = try OwnedVirtualMachineDirectory.checkedURL(tart: tart, name: stageName)
            let owner: OwnedVirtualMachineDirectory
            do {
                try await tart.clone(sourceName: vmName, newName: stageName)
                owner = try OwnedVirtualMachineDirectory.create(
                    tart: tart,
                    staging: staging,
                    name: newName,
                    source: vmName
                )
                try Task.checkCancellation()
                try OwnedVirtualMachineDirectory.publish(staging: staging, destination: destination)
            } catch {
                // A command that survived SIGKILL may still write to staging. Quarantine that
                // unique name; it can never overwrite the published slot or a subsequent clone.
                if let timeout = error as? ShellProcessTimeoutError, !timeout.didExit {
                    log("unreaped clone command; leaving unpublished staging directory \(staging.path)")
                } else if (try? OwnedVirtualMachineDirectory.checkedURL(tart: tart, name: stageName)) != nil {
                    try? FileManager.default.removeItem(at: staging)
                }
                throw error
            }
            return TartVirtualMachine(
                tart: tart,
                vmName: newName,
                inspector: inspector,
                timing: timing,
                ownership: owner,
                lease: lease
            )
        } catch {
            retainLeaseForUnreapedCommand(error, lease: lease)
            lease.release()
            throw error
        }
    }

    public func delete() async throws {
        // A caller already cancelled by Stop/Quit must still finish cleanup before releasing the
        // slot. All external commands below own bounded termination rather than abandoned races.
        try await Task.detached { [self] in
            let temporaryLease = try lease == nil ? VirtualMachineLease(tart: tart, name: vmName) : nil
            defer { temporaryLease?.release(); lease?.release() }
            let activeLease = lease ?? temporaryLease
            try activeLease?.ensureReady()
            guard let owner = try OwnedVirtualMachineDirectory.read(tart: tart, name: vmName) else {
                return
            }
            if let ownership, ownership.token != owner.token {
                throw TartVirtualMachineError.unownedDirectory(tart.virtualMachineDirectoryURL(name: vmName).path)
            }
            do {
                try await deleteVerified(owner: owner)
            } catch {
                retainLeaseForUnreapedCommand(error, lease: activeLease)
                throw error
            }
        }.value
    }

    public func getIPAddress() async throws -> String {
        try Task.checkCancellation()
        try lease?.ensureReady()
        if let ownership { try ownership.verify(tart: tart) }
        return try await tart.getIPAddress(ofVirtualMachineNamed: name)
    }

    public func forceStop() async {
        await Task.detached { [self] in
            do {
                let temporaryLease = try lease == nil ? VirtualMachineLease(tart: tart, name: vmName) : nil
                defer { temporaryLease?.release() }
                let activeLease = lease ?? temporaryLease
                try activeLease?.ensureReady()
                if let ownership { try ownership.verify(tart: tart) }
                let owner: OwnedVirtualMachineDirectory?
                do {
                    owner = try OwnedVirtualMachineDirectory.read(tart: tart, name: vmName)
                } catch TartVirtualMachineError.unownedDirectory where ownership == nil {
                    owner = nil  // The editor may stop only its own base-image process handle.
                }
                do {
                    try await stop(owner: owner, name: vmName)
                } catch {
                    retainLeaseForUnreapedCommand(error, lease: activeLease)
                    throw error
                }
            } catch {
                log("forced stop could not finish: \(error.localizedDescription)")
            }
        }.value
    }
}

private extension TartVirtualMachine {
    func ensureAbsent(name: String) async throws {
        guard let owner = try OwnedVirtualMachineDirectory.read(tart: tart, name: name, source: vmName) else {
            return
        }
        log("cleaning owned leftover clone \(name)")
        try await deleteVerified(owner: owner)
    }

    func deleteVerified(owner: OwnedVirtualMachineDirectory) async throws {
        try owner.verify(tart: tart)
        try await stop(owner: owner, name: owner.name)
        try owner.verify(tart: tart)
        let directory = try OwnedVirtualMachineDirectory.checkedURL(tart: tart, name: owner.name)
        do {
            try await tart.delete(name: owner.name)
        } catch TartError.virtualMachineDoesNotExist {
            // Missing config.json does not mean that the disk directory was removed.
        }
        if OwnedVirtualMachineDirectory.exists(directory) {
            try owner.verify(tart: tart)
            try FileManager.default.removeItem(at: directory)
        }
        guard !OwnedVirtualMachineDirectory.exists(directory) else {
            throw TartVirtualMachineError.directoryNotRemoved(directory.path)
        }
    }

    func stop(owner: OwnedVirtualMachineDirectory?, name: String) async throws {
        if let owner {
            try owner.verify(tart: tart)
            do {
                try await tart.stop(name: name, timeout: .seconds(20))
            } catch TartError.virtualMachineDoesNotExist {
                // Recover through process identity/disk holders when the lock pathname is missing.
            } catch TartError.virtualMachineIsNotRunning {
                // Its helper may still be alive.
            } catch let error as ShellProcessTimeoutError where !error.didExit {
                throw error
            } catch {
                log("tart stop failed; checking the run process and disk holders: \(error.localizedDescription)")
            }
        }
        if name == vmName, let process = lock.withLock({ runProcess }), process.isRunning {
            process.interrupt()
            if !(await process.waitForExit(timeout: timing.interrupt)) { process.kill() }
            guard await process.waitForExit(timeout: timing.kill) else {
                throw TartVirtualMachineError.processStillRunning(process.processIdentifier)
            }
        }
        // An editor's base image has no marker: only its own process handle may be signaled.
        guard let owner else {
            return
        }
        try await reapHelpers(owner: owner, name: name)
    }

    func reapHelpers(owner: OwnedVirtualMachineDirectory, name: String) async throws {
        try owner.verify(tart: tart)
        let processes = try await inspector.processes(tart: tart, name: name)
        if let unrelated = processes.first(where: { !$0.mayKill }) {
            throw TartVirtualMachineError.unrelatedDiskHolder(unrelated.pid)
        }
        for process in processes {
            log("stopping lingering pid \(process.pid) (\(process.executable)) for \(name)")
            try inspector.kill(process)
        }
        let deadline = ContinuousClock.now.advanced(by: timing.kill)
        for process in processes {
            while !inspector.hasExited(process), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard inspector.hasExited(process) else { throw TartVirtualMachineError.processStillRunning(process.pid) }
        }
        // Close the lookup/exit window before dropping the only disk pathname used to identify a helper.
        let remaining = try await inspector.processes(tart: tart, name: name)
        if let process = remaining.first { throw TartVirtualMachineError.processStillRunning(process.pid) }
    }

    func retainLeaseForUnreapedCommand(_ error: Error, lease: VirtualMachineLease?) {
        if let timeout = error as? ShellProcessTimeoutError, !timeout.didExit {
            lease?.keepUntilExit(timeout.process)
        } else if let process = lock.withLock({ runProcess }), process.isRunning {
            lease?.keepUntilExit(process)
        }
    }

    func log(_ message: String) { tart.logger?.info("[vm \(vmName)] \(message)") }
}
