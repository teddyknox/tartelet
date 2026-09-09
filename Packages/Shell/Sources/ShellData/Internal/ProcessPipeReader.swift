import Foundation

/// The dispatch source serializes reads and descriptor closure. Work per event is capped so a
/// noisy writer cannot starve cancellation. `cancel` is the only cross-queue operation.
final class ProcessPipeReader: @unchecked Sendable {
    private let source: DispatchSourceRead

    init(handle: FileHandle, didRead: @escaping (Data) -> Void, didClose: @escaping () -> Void) {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue(label: "ProcessShell.pipe", qos: .utility)
        )
        self.source = source
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 16_384)
            for _ in 0 ..< 16 {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    didRead(Data(buffer.prefix(count)))
                } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    self?.source.cancel()
                    return
                } else {
                    return
                }
            }
        }
        source.setCancelHandler {
            try? handle.close()
            didClose()
        }
        source.resume()
    }

    func cancel() { source.cancel() }
}
