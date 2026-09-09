import Foundation
import LoggingDomain
import ShellDomain
import VirtualMachineDomain

public enum TartVirtualMachineError: LocalizedError, Equatable {
    case directoryNotRemoved(String)

    public var errorDescription: String? {
        switch self {
        case let .directoryNotRemoved(path):
            "The virtual machine directory at \(path) could not be removed"
        }
    }
}

public final class TartVirtualMachine: VirtualMachine {
    /// Graceful window `tart stop` gives the virtual machine before it sends `SIGKILL`.
    static let stopTimeout: Duration = .seconds(20)
    /// Bound on the `tart stop` command itself.
    static let stopCommandTimeout: Duration = .seconds(45)
    /// How long to wait after `SIGINT` before sending `SIGKILL` to our own `tart run`.
    static let interruptGracePeriod: Duration = .seconds(10)
    /// How long to wait after `SIGKILL` for the process to be reaped.
    static let killGracePeriod: Duration = .seconds(10)
    /// `SIGINT` to `SIGKILL` escalation when the fleet cancels a running machine.
    static let cancellationGracePeriod: Duration = .seconds(15)
    /// Bound on looking for a lingering Virtualization helper.
    static let helperLookupTimeout: Duration = .seconds(15)

    public var name: String {
        vmName
    }
    public var canStart: Bool {
        true
    }

    private let tart: Tart
    private let vmName: String
    private let lock = NSLock()
    private var runProcess: ShellProcess?
    private var logger: Logger? {
        tart.logger
    }

    public init(tart: Tart, vmName: String) {
        self.tart = tart
        self.vmName = vmName
    }

    public func start(observer: VirtualMachineStartObserver?) async throws {
        // A fleet that was stopped between clone and start must not boot a machine just to kill it.
        try Task.checkCancellation()
        let process = try tart.launchRun(name: vmName)
        lock.withLock {
            runProcess = process
        }
        defer {
            lock.withLock {
                runProcess = nil
            }
        }
        let name = vmName
        let logger = self.logger
        try await withTaskCancellationHandler {
            _ = try await process.waitForExit()
        } onCancel: {
            // Ask tart to stop the machine, as Ctrl-C would, and kill it if it does not comply, so
            // a cancelled fleet still stops promptly even when tart is wedged.
            Task.detached {
                await Self.interruptEscalatingToKill(
                    process,
                    gracePeriod: Self.cancellationGracePeriod,
                    virtualMachineName: name,
                    logger: logger
                )
            }
        }
    }

    public func clone(named newName: String) async throws -> VirtualMachine {
        // A directory left behind by an earlier cycle (or an orphaned process still running the
        // machine) must go first; cloning over it produces a machine that never boots properly.
        try await Self.ensureAbsent(tart: tart, name: newName)
        try await tart.clone(sourceName: name, newName: newName)
        return TartVirtualMachine(tart: tart, vmName: newName)
    }

    public func delete() async throws {
        try await Self.deleteVerified(tart: tart, name: vmName)
    }

    public func getIPAddress() async throws -> String {
        try await tart.getIPAddress(ofVirtualMachineNamed: name)
    }

    public func forceStop() async {
        let process = lock.withLock { runProcess }
        // 1. `tart stop`: finds the machine's process through its lock file, sends SIGINT and
        //    SIGKILLs it after the timeout. Works even when we hold no handle to the process.
        let tart = self.tart
        let name = vmName
        do {
            try await withTimeout(Self.stopCommandTimeout) {
                try await tart.stop(name: name, timeout: Self.stopTimeout)
            }
            log("tart stop returned")
        } catch let error as TartError {
            log("tart stop: \(error.localizedDescription)")
        } catch {
            log("tart stop failed: \(error.localizedDescription)")
        }
        // 2. Our own `tart run`, in case the lock file was gone and tart could not find it.
        if let process, process.isRunning {
            log("tart run (pid \(process.processIdentifier)) is still running after tart stop; interrupting it")
            await Self.interruptEscalatingToKill(
                process,
                gracePeriod: Self.interruptGracePeriod,
                virtualMachineName: name,
                logger: logger
            )
        }
        // 3. The Virtualization.framework helper is a separate process that can outlive tart. It
        //    counts toward the system's limit on concurrent machines, so it must not linger.
        await killLingeringVirtualizationHelper()
    }
}

extension TartVirtualMachine {
    /// Deletes the machine and makes sure its directory is gone afterwards.
    ///
    /// tart considers a directory without a `config.json` to be a machine that "does not exist"
    /// and refuses to delete it, yet a clone into that name then never boots properly. Whatever
    /// tart says, the directory must not survive.
    static func deleteVerified(tart: Tart, name: String) async throws {
        let directoryURL = tart.virtualMachineDirectoryURL(name: name)
        let fileManager = FileManager.default
        do {
            try await tart.delete(name: name)
        } catch TartError.virtualMachineDoesNotExist {
            if fileManager.fileExists(atPath: directoryURL.path) {
                tart.logger?.info(
                    "tart delete reported that \(name) does not exist but \(directoryURL.path) is still there;"
                    + " removing the directory"
                )
            }
        }
        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
        if fileManager.fileExists(atPath: directoryURL.path) {
            throw TartVirtualMachineError.directoryNotRemoved(directoryURL.path)
        }
    }

    /// Stops and deletes whatever occupies the slot's name before it is cloned into.
    static func ensureAbsent(tart: Tart, name: String) async throws {
        let directoryURL = tart.virtualMachineDirectoryURL(name: name)
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return
        }
        tart.logger?.info(
            "A virtual machine directory named \(name) already exists at \(directoryURL.path);"
            + " cleaning it up before cloning"
        )
        do {
            try await withTimeout(stopCommandTimeout) {
                try await tart.stop(name: name, timeout: stopTimeout)
            }
            tart.logger?.info("Stopped a virtual machine named \(name) that was still running")
        } catch let error as TartError {
            tart.logger?.info("tart stop for the leftover \(name): \(error.localizedDescription)")
        } catch {
            tart.logger?.info("tart stop for the leftover \(name) failed: \(error.localizedDescription)")
        }
        try await deleteVerified(tart: tart, name: name)
    }

    static func interruptEscalatingToKill(
        _ process: ShellProcess,
        gracePeriod: Duration,
        virtualMachineName: String,
        logger: Logger?
    ) async {
        guard process.isRunning else {
            return
        }
        process.interrupt()
        if await process.waitForExit(timeout: gracePeriod) {
            return
        }
        logger?.info(
            "tart run for \(virtualMachineName) (pid \(process.processIdentifier)) did not exit within"
            + " \(FleetDurationFormatter.string(from: gracePeriod)) of SIGINT; sending SIGKILL"
        )
        process.kill()
        if !(await process.waitForExit(timeout: killGracePeriod)) {
            logger?.error(
                "tart run for \(virtualMachineName) (pid \(process.processIdentifier)) is still running after SIGKILL"
            )
        }
    }
}

private extension TartVirtualMachine {
    private func killLingeringVirtualizationHelper() async {
        let diskURL = tart.virtualMachineDirectoryURL(name: vmName).appendingPathComponent("disk.img")
        guard FileManager.default.fileExists(atPath: diskURL.path) else {
            return
        }
        let inspector = HostProcessInspector(shell: tart.shell)
        let processIdentifiers: [Int32]
        do {
            processIdentifiers = try await withTimeout(Self.helperLookupTimeout) {
                try await inspector.processIdentifiers(holdingFileAt: diskURL)
            }
        } catch {
            log("could not look for processes holding \(diskURL.lastPathComponent): \(error.localizedDescription)")
            return
        }
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        for processIdentifier in processIdentifiers where processIdentifier != ownProcessIdentifier {
            let commandName = (try? await inspector.commandName(ofProcess: processIdentifier)) ?? ""
            let isVirtualizationProcess = commandName.contains("Virtualization")
                || commandName.hasSuffix("/tart")
                || commandName == "tart"
            guard isVirtualizationProcess else {
                log("not killing pid \(processIdentifier) (\(commandName)) even though it holds the disk image")
                continue
            }
            log("killing lingering process \(processIdentifier) (\(commandName)) that still holds the disk image")
            Darwin.kill(processIdentifier, SIGKILL)
        }
    }

    private func log(_ message: String) {
        logger?.info("[vm \(vmName)] \(message)")
    }
}
