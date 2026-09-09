import Foundation

/// Thread-safe registry of the child processes spawned by ``ProcessShell``.
///
/// Tartelet spawns a long-running `tart run` process for each running virtual machine. Neither
/// these processes nor the `Virtualization.framework` virtual machines they manage are torn down
/// automatically when Tartelet exits, so a crash or restart leaks virtual machines that keep
/// holding onto the limited number of concurrent VMs macOS allows. The registry lets the app
/// terminate every spawned process when it is about to quit, giving `tart` a chance to shut its
/// virtual machine down cleanly.
public final class ProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: Set<SendableProcess> = []
    private var isTerminating = false

    public init() {}

    /// Launch and registration share the termination barrier. A fast child cannot unregister
    /// before it is registered, and no child can start after the quit snapshot is taken.
    func launch(_ process: SendableProcess) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminating else {
            throw CancellationError()
        }
        processes.insert(process)
        do {
            try process.process.run()
        } catch {
            processes.remove(process)
            throw error
        }
    }

    var registeredCount: Int { lock.withLock { processes.count } }

    func unregister(_ process: SendableProcess) {
        lock.lock()
        defer { lock.unlock() }
        processes.remove(process)
    }

    /// Interrupts every running process and waits for them to exit.
    ///
    /// Each process is first sent `SIGINT` — the same signal as pressing Ctrl-C in a terminal —
    /// which `tart` handles by shutting its virtual machine down cleanly. Any process still
    /// running after `gracePeriod` seconds is force-killed (`SIGKILL`) as a last resort. This
    /// blocks the calling thread and is intended to be called while the app is terminating.
    public func terminateAll(gracePeriod: TimeInterval = 10) {
        lock.lock()
        isTerminating = true
        let snapshot = processes.map(\.process)
        lock.unlock()
        let running = snapshot.filter { $0.isRunning }
        guard !running.isEmpty else {
            return
        }
        for process in running {
            process.interrupt()
        }
        let deadline = Date().addingTimeInterval(gracePeriod)
        while Date() < deadline, running.contains(where: { $0.isRunning }) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        for process in running where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
