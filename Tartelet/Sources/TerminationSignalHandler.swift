import Darwin
import Foundation

/// Forwards `SIGTERM`/`SIGINT` to a callback on the main queue so the app can shut down cleanly.
///
/// AppKit only runs `applicationWillTerminate(_:)` for "graceful" quits (the Quit menu, logout and
/// restart). A bare `SIGTERM` — as sent by `kill`, `pkill` or `launchctl bootout` — terminates the
/// process immediately, before any cleanup runs, which leaks the `tart` virtual machines Tartelet
/// spawned. This handler intercepts those signals and routes them through `NSApplication.terminate`
/// so `applicationWillTerminate(_:)` runs and the virtual machines are torn down.
///
/// A `sigaction` handler is used rather than ignoring the signal (`SIG_IGN`) on purpose: ignored
/// signal dispositions are inherited across `exec`, so child `tart` processes would inherit them
/// and stop responding to signals. Installed handlers are instead reset to the default disposition
/// in the child after `exec`, leaving `tart`'s own signal handling intact.
enum TerminationSignalHandler {
    /// Write end of the self-pipe, read by the C signal handler. Stored globally because the signal
    /// handler must be a C function and cannot capture context.
    private nonisolated(unsafe) static var writeFileDescriptor: Int32 = -1
    private nonisolated(unsafe) static var readSource: DispatchSourceRead?

    static func install(onTermination: @escaping () -> Void) {
        guard readSource == nil else {
            return
        }
        var fileDescriptors: [Int32] = [-1, -1]
        guard pipe(&fileDescriptors) == 0 else {
            return
        }
        let readFileDescriptor = fileDescriptors[0]
        writeFileDescriptor = fileDescriptors[1]
        // Close both ends in spawned child processes so they don't leak into `tart`.
        _ = fcntl(readFileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFileDescriptor, F_SETFD, FD_CLOEXEC)

        let source = DispatchSource.makeReadSource(fileDescriptor: readFileDescriptor, queue: .main)
        source.setEventHandler {
            var byte: UInt8 = 0
            _ = read(readFileDescriptor, &byte, 1)
            onTermination()
        }
        source.resume()
        readSource = source

        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in
            // Async-signal-safe: only write a single byte to wake the dispatch source.
            var byte: UInt8 = 1
            _ = write(TerminationSignalHandler.writeFileDescriptor, &byte, 1)
        }
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(SIGTERM, &action, nil)
        sigaction(SIGINT, &action, nil)
    }
}
