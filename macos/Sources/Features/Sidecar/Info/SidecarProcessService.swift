import Darwin
import Foundation

struct SidecarProcessSnapshot: Equatable, Sendable {
    var processes: [SidecarProcessInfo]
    var listeningPorts: [SidecarListeningPort]

    static let empty = SidecarProcessSnapshot(processes: [], listeningPorts: [])
}

struct SidecarProcessInfo: Hashable, Identifiable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let name: String
    let startedAt: Date

    var id: Int32 { pid }
}

struct SidecarListeningPort: Identifiable, Hashable, Sendable {
    let pid: Int32
    let address: String
    let port: UInt16

    var id: String { "\(pid):\(address):\(port)" }
}

/// Reads process and socket metadata through libproc.
///
/// This actor keeps all blocking system inspection off the main actor. It
/// inspects only the bounded foreground process tree plus its shell parent; it
/// never scans every process or socket on the machine.
actor SidecarProcessService {
    static let shared = SidecarProcessService()

    private static let processCacheDuration: TimeInterval = 2
    private static let portCacheDuration: TimeInterval = 4

    private var processCache: SidecarProcessTreeCache?
    private var portCache: [SidecarProcessIdentity: SidecarPortCacheEntry] = [:]

    func snapshot(foregroundPID: Int?) -> SidecarProcessSnapshot {
        guard let foregroundPID, let rootPID = Int32(exactly: foregroundPID) else {
            return .empty
        }

        guard let root = processInfo(pid: rootPID) else { return .empty }
        let now = Date()
        let rootIdentity = SidecarProcessIdentity(root)
        let rootChildren = childPIDs(of: root.pid)
        let processes: [SidecarProcessInfo]
        if let cached = processCache,
           cached.root == rootIdentity,
           cached.rootChildren == rootChildren,
           now.timeIntervalSince(cached.loadedAt)
            < Self.processCacheDuration {
            processes = cached.processes
        } else {
            var refreshed = processTree(
                root: root,
                rootChildren: rootChildren,
                limit: 64
            )
            if !isShell(root.name),
               !refreshed.contains(where: { $0.pid == root.parentPID }),
               let parent = processInfo(pid: root.parentPID),
               isShell(parent.name) {
                refreshed.append(parent)
            }
            processes = refreshed
            processCache = .init(
                root: rootIdentity,
                rootChildren: rootChildren,
                processes: refreshed,
                loadedAt: now
            )
        }

        var ports = Set<SidecarListeningPort>()
        for process in processes {
            guard !Task.isCancelled else { return .empty }
            let identity = SidecarProcessIdentity(process)
            if let cached = portCache[identity],
               now.timeIntervalSince(cached.loadedAt)
                < Self.portCacheDuration {
                ports.formUnion(cached.ports)
            } else {
                let refreshed = listeningPorts(pid: process.pid)
                portCache[identity] = .init(
                    ports: refreshed,
                    loadedAt: now
                )
                ports.formUnion(refreshed)
            }
        }
        let activeIdentities = Set(processes.map(SidecarProcessIdentity.init))
        portCache = portCache.filter { activeIdentities.contains($0.key) }

        return SidecarProcessSnapshot(
            processes: processes,
            listeningPorts: ports.sorted {
                if $0.port != $1.port { return $0.port < $1.port }
                if $0.address != $1.address { return $0.address < $1.address }
                return $0.pid < $1.pid
            }
        )
    }

    private func processTree(
        root: SidecarProcessInfo,
        rootChildren: [Int32],
        limit: Int
    ) -> [SidecarProcessInfo] {
        var pending = rootChildren
        var seen: Set<Int32> = [root.pid]
        var result = [root]

        while let pid = pending.first, result.count < limit {
            guard !Task.isCancelled else { return [] }
            pending.removeFirst()
            guard seen.insert(pid).inserted else { continue }
            if let info = processInfo(pid: pid) {
                result.append(info)
                pending.append(contentsOf: childPIDs(of: pid))
            }
        }

        return result
    }

    private func childPIDs(of pid: Int32) -> [Int32] {
        var children = [pid_t](repeating: 0, count: 64)
        let childCount = children.withUnsafeMutableBytes {
            proc_listchildpids(pid, $0.baseAddress, Int32($0.count))
        }
        guard childCount > 0 else { return [] }

        return children
            .prefix(min(Int(childCount), children.count))
            .filter { $0 > 0 }
    }

    private func processInfo(pid: Int32) -> SidecarProcessInfo? {
        guard pid > 0 else { return nil }

        var info = proc_bsdinfo()
        let byteCount = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                $0,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
        }
        guard byteCount == MemoryLayout<proc_bsdinfo>.size else { return nil }

        var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = nameLength > 0 ? String(cString: nameBuffer) : "Process"

        let start = TimeInterval(info.pbi_start_tvsec)
            + TimeInterval(info.pbi_start_tvusec) / 1_000_000

        return SidecarProcessInfo(
            pid: pid,
            parentPID: Int32(bitPattern: info.pbi_ppid),
            name: name,
            startedAt: Date(timeIntervalSince1970: start)
        )
    }

    private func isShell(_ name: String) -> Bool {
        switch name.lowercased() {
        case "bash", "dash", "fish", "ksh", "nu", "sh", "tcsh", "zsh":
            true
        default:
            false
        }
    }

    private func listeningPorts(pid: Int32) -> Set<SidecarListeningPort> {
        let requiredBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard requiredBytes > 0 else { return [] }

        let capacity = min(
            Int(requiredBytes) / MemoryLayout<proc_fdinfo>.size + 32,
            4_096
        )
        var fileDescriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: capacity
        )
        let byteCount = fileDescriptors.withUnsafeMutableBytes {
            proc_pidinfo(
                pid,
                PROC_PIDLISTFDS,
                0,
                $0.baseAddress,
                Int32($0.count)
            )
        }
        guard byteCount > 0 else { return [] }

        let descriptorCount = min(
            Int(byteCount) / MemoryLayout<proc_fdinfo>.size,
            fileDescriptors.count
        )
        var result = Set<SidecarListeningPort>()

        for descriptor in fileDescriptors.prefix(descriptorCount)
        where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
            guard !Task.isCancelled else { return [] }
            var socket = socket_fdinfo()
            let socketByteCount = withUnsafeMutablePointer(to: &socket) {
                proc_pidfdinfo(
                    pid,
                    descriptor.proc_fd,
                    PROC_PIDFDSOCKETINFO,
                    $0,
                    Int32(MemoryLayout<socket_fdinfo>.size)
                )
            }
            guard socketByteCount == MemoryLayout<socket_fdinfo>.size,
                  socket.psi.soi_kind == SOCKINFO_TCP else {
                continue
            }

            let tcp = socket.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }

            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            guard port != 0 else { continue }

            result.insert(SidecarListeningPort(
                pid: pid,
                address: localAddress(tcp.tcpsi_ini),
                port: port
            ))
        }

        return result
    }

    private func localAddress(_ info: in_sockinfo) -> String {
        if info.insi_vflag & UInt8(INI_IPV4) != 0 {
            var address = info.insi_laddr.ina_46.i46a_addr4
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                return String(cString: buffer)
            }
        }

        if info.insi_vflag & UInt8(INI_IPV6) != 0 {
            var address = info.insi_laddr.ina_6
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                return String(cString: buffer)
            }
        }

        return "*"
    }
}

private struct SidecarProcessIdentity: Hashable {
    let pid: Int32
    let startedAt: Date

    init(_ process: SidecarProcessInfo) {
        self.pid = process.pid
        self.startedAt = process.startedAt
    }
}

private struct SidecarProcessTreeCache {
    let root: SidecarProcessIdentity
    let rootChildren: [Int32]
    let processes: [SidecarProcessInfo]
    let loadedAt: Date
}

private struct SidecarPortCacheEntry {
    let ports: Set<SidecarListeningPort>
    let loadedAt: Date
}
