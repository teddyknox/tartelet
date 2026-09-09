import Darwin
import Foundation
import ShellDomain

struct HostVMProcess: Equatable {
    let pid: Int32
    let executable: String
    let startedAtSeconds: UInt64
    let startedAtMicroseconds: UInt64
    let mayKill: Bool
}

protocol HostProcessInspecting {
    func processes(tart: Tart, name: String) async throws -> [HostVMProcess]
    func kill(_ process: HostVMProcess) throws
    func hasExited(_ process: HostVMProcess) -> Bool
}

/// Inspection commands have process deadlines. Kernel process identity (including start time)
/// is checked again before signaling, and argv/environment are read without shell tokenization.
struct HostProcessInspector: HostProcessInspecting {
    static let helperExecutable =
        "/System/Library/Frameworks/Virtualization.framework/Versions/A/"
        + "XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/"
        + "com.apple.Virtualization.VirtualMachine"
    let shell: Shell

    func processes(tart: Tart, name: String) async throws -> [HostVMProcess] {
        let directory = try OwnedVirtualMachineDirectory.checkedURL(tart: tart, name: name)
        var holders: Set<Int32> = []
        for filename in ["disk.img", "config.json"] {
            let file = directory.appendingPathComponent(filename)
            if OwnedVirtualMachineDirectory.exists(file) {
                holders.formUnion(try await identifiers(command: "/usr/sbin/lsof", arguments: ["-t", "--", file.path]))
            }
        }
        // A missing config pathname makes tart stop ineffective. Find the orphan run by its
        // exact executable, argument vector and home, even if it no longer holds a named file.
        let candidates = try await identifiers(
            command: "/usr/bin/pgrep",
            arguments: ["-x", "-u", String(getuid()), "tart"]
        )
        let tartPath = try URL(fileURLWithPath: tart.executablePath()).resolvingSymlinksInPath().path
        var processes: [HostVMProcess] = []
        for pid in holders.union(candidates) where pid != getpid() {
            guard let identity = Self.identity(pid) else {
                if Darwin.kill(pid, 0) == 0 || errno != ESRCH {
                    throw TartVirtualMachineError.processNotInspectable(pid)
                }
                continue
            }
            let arguments = Self.argumentsAndEnvironment(pid)
            let isOwnTart =
                identity.executable == tartPath
                && arguments.map { values in
                    Self.isRun(
                        arguments: values.arguments,
                        environment: values.environment,
                        home: tart.homeFolderURL,
                        name: name
                    )
                } == true
            let isHelper = identity.executable == Self.helperExecutable && holders.contains(pid)
            guard holders.contains(pid) || isOwnTart else { continue }
            processes.append(
                HostVMProcess(
                    pid: pid,
                    executable: identity.executable,
                    startedAtSeconds: identity.startedAtSeconds,
                    startedAtMicroseconds: identity.startedAtMicroseconds,
                    mayKill: isHelper || isOwnTart
                )
            )
        }
        return processes
    }

    func kill(_ process: HostVMProcess) throws {
        guard process.mayKill else { throw TartVirtualMachineError.unrelatedDiskHolder(process.pid) }
        guard !hasExited(process) else {
            return
        }
        guard Darwin.kill(process.pid, SIGKILL) == 0 || errno == ESRCH else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func hasExited(_ process: HostVMProcess) -> Bool {
        guard let current = Self.identity(process.pid) else {
            return Darwin.kill(process.pid, 0) != 0 && errno == ESRCH
        }
        return current.startedAtSeconds != process.startedAtSeconds
            || current.startedAtMicroseconds != process.startedAtMicroseconds
            || current.executable != process.executable
    }

    private func identifiers(command: String, arguments: [String]) async throws -> Set<Int32> {
        let output: String
        do {
            output = try await shell.runExecutable(atPath: command, withArguments: arguments, timeout: .seconds(15))
        } catch let error as ShellExecutionError where error.terminationStatus == 1 {
            // lsof/pgrep use 1 for no matches. A diagnostic is not a trustworthy empty result.
            guard error.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw error }
            output = error.standardOutput
        }
        return Set(
            try output.split(whereSeparator: \.isNewline).map { line in
                guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid > 0 else {
                    throw TartVirtualMachineError.invalidProcessList
                }
                return pid
            }
        )
    }

    private static func identity(_ pid: Int32) -> HostVMProcess? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        // PROC_PIDPATHINFO_MAXSIZE is (4 * MAXPATHLEN), a macro Swift does not import.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
            return nil
        }
        return HostVMProcess(
            pid: pid,
            executable: URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path,
            startedAtSeconds: info.pbi_start_tvsec,
            startedAtMicroseconds: info.pbi_start_tvusec,
            mayKill: false
        )
    }

    static func isRun(arguments: [String], environment: [String: String], home: URL, name: String) -> Bool {
        guard arguments.count >= 3, arguments[1] == "run", arguments.last == name else {
            return false
        }
        // macOS can hide environment variables (e.g. for platform binaries). Never interpret
        // missing evidence as the default home: every owned Tartelet run sets TART_HOME explicitly.
        guard let path = environment["TART_HOME"] else {
            return false
        }
        let configuredHome = URL(fileURLWithPath: path)
        return configuredHome.resolvingSymlinksInPath().path == home.resolvingSymlinksInPath().path
    }

    static func argumentsAndEnvironment(_ pid: Int32) -> (arguments: [String], environment: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 4, size <= 1_048_576 else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0 else {
            return nil
        }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0 else {
            return nil
        }
        var offset = 4
        func next() -> String? {
            guard offset < size, let end = bytes[offset ..< size].firstIndex(of: 0) else {
                return nil
            }
            defer { offset = end + 1 }
            return String(bytes: bytes[offset ..< end], encoding: .utf8)
        }
        guard next() != nil else { // executable pathname
            return nil
        }
        while offset < size, bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0 ..< count {
            guard let argument = next() else {
                return nil
            }
            arguments.append(argument)
        }
        var environment: [String: String] = [:]
        while let item = next(), !item.isEmpty {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { environment[String(pair[0])] = String(pair[1]) }
        }
        return (arguments, environment)
    }
}
