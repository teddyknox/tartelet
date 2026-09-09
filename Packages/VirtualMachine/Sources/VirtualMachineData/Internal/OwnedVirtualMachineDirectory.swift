import CryptoKit
import Darwin
import Foundation
import ShellDomain

/// Persistent proof refers to this directory's inode, not just a reusable VM name. A clone is
/// marked in a private staging directory and only then published with a non-replacing rename.
struct OwnedVirtualMachineDirectory: Codable {
    static let markerName = ".tartelet-owner.json"
    let version: Int
    let token: UUID
    let home: String
    let name: String
    let source: String
    let device: Int32
    let inode: UInt64

    static func checkedURL(tart: Tart, name: String) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw TartVirtualMachineError.unsafeDirectory(name)
        }
        let parent = tart.homeFolderURL.appendingPathComponent("vms", isDirectory: true).standardizedFileURL
        guard parent.resolvingSymlinksInPath().path == parent.path else {
            throw TartVirtualMachineError.unsafeDirectory(parent.path)
        }
        let url = parent.appendingPathComponent(name, isDirectory: true)
        var info = stat()
        if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFDIR {
            throw TartVirtualMachineError.unsafeDirectory(url.path)
        }
        return url
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    static func create(tart: Tart, staging: URL, name: String, source: String) throws -> Self {
        var info = stat()
        guard lstat(staging.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw TartVirtualMachineError.unsafeDirectory(staging.path)
        }
        let owner = Self(
            version: 1,
            token: UUID(),
            home: tart.homeFolderURL.path,
            name: name,
            source: source,
            device: info.st_dev,
            inode: info.st_ino
        )
        try JSONEncoder().encode(owner).write(to: staging.appendingPathComponent(markerName), options: .atomic)
        return owner
    }

    static func read(tart: Tart, name: String, source: String? = nil) throws -> Self? {
        let url = try checkedURL(tart: tart, name: name)
        guard exists(url) else {
            return nil
        }
        var info = stat()
        _ = lstat(url.path, &info)
        let marker = url.appendingPathComponent(markerName)
        guard marker.resolvingSymlinksInPath().path == marker.path,
            let data = try? Data(contentsOf: marker),
            let owner = try? JSONDecoder().decode(Self.self, from: data),
            owner.version == 1, owner.home == tart.homeFolderURL.path,
            owner.name == name, owner.name != owner.source,
            source == nil || source == owner.source,
            owner.device == info.st_dev, owner.inode == info.st_ino
        else {
            throw TartVirtualMachineError.unownedDirectory(url.path)
        }
        // Never follow a disk/config symlink into a base image or another VM during inspection.
        for filename in ["disk.img", "config.json", "nvram.bin"] {
            let file = url.appendingPathComponent(filename)
            var fileInfo = stat()
            if lstat(file.path, &fileInfo) == 0,
                file.resolvingSymlinksInPath().path != file.path || fileInfo.st_nlink != 1 {
                throw TartVirtualMachineError.unsafeDirectory(file.path)
            }
        }
        return owner
    }

    func verify(tart: Tart) throws {
        guard let current = try Self.read(tart: tart, name: name, source: source), current.token == token else {
            throw TartVirtualMachineError.unownedDirectory(tart.virtualMachineDirectoryURL(name: name).path)
        }
    }

    static func publish(staging: URL, destination: URL) throws {
        guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

/// A separate lock survives directory removal. It prevents two Tartelet processes from running
/// or deleting the same slot. Release explicitly on deletion; abandoned SSH tasks may retain a VM.
final class VirtualMachineLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private var pendingProcess: Int32?
    private let quarantineURL: URL

    init(tart: Tart, name: String) throws {
        let directory = tart.homeFolderURL.appendingPathComponent(".tartelet-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard directory.resolvingSymlinksInPath().path == directory.path else {
            throw TartVirtualMachineError.unsafeDirectory(directory.path)
        }
        // Fixed-length encoding also supports slot names near the filesystem's filename limit.
        let filename = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        quarantineURL = directory.appendingPathComponent(filename + ".quarantine")
        descriptor = open(
            directory.appendingPathComponent(filename).path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            descriptor = -1
            throw TartVirtualMachineError.slotInUse(name)
        }
        if FileManager.default.fileExists(atPath: quarantineURL.path) {
            close(descriptor)
            descriptor = -1
            throw TartVirtualMachineError.quarantinedSlot(quarantineURL.path)
        }
    }

    func ensureReady() throws {
        try lock.withLock {
            guard descriptor >= 0 else { throw TartVirtualMachineError.releasedLease }
            if let pendingProcess { throw TartVirtualMachineError.processStillRunning(pendingProcess) }
        }
    }

    /// An unreaped name-based command must not touch a later clone. Keep the lock until it
    /// exits; persist a quarantine in case the app quits before that happens.
    func keepUntilExit(_ process: ShellProcess) {
        let shouldWait = lock.withLock {
            guard pendingProcess == nil else {
                return false
            }
            pendingProcess = process.processIdentifier
            return true
        }
        guard shouldWait else {
            return
        }
        // If persistence fails, the in-process lease still stays held through actual exit.
        try? Data("Unreaped process \(process.processIdentifier)\n".utf8).write(to: quarantineURL, options: .atomic)
        Task.detached { [self] in
            _ = try? await process.waitForExit()
            try? FileManager.default.removeItem(at: quarantineURL)
            lock.withLock { pendingProcess = nil }
            release()
        }
    }

    func release() {
        lock.withLock {
            guard descriptor >= 0, pendingProcess == nil else {
                return
            }
            close(descriptor)
            descriptor = -1
        }
    }

    deinit { release() }
}
