import Darwin
import Foundation

struct SidecarProcessSnapshot: Equatable, Sendable {
    var processes: [SidecarProcessInfo]
    var listeningPorts: [SidecarListeningPort]
    var resources: SidecarResourceSnapshot

    static let empty = SidecarProcessSnapshot(
        processes: [],
        listeningPorts: [],
        resources: .empty
    )
}

struct SidecarResourceSnapshot: Equatable, Sendable {
    let cpuPercent: Double?
    let systemCPUPercent: Double?
    let memoryBytes: UInt64
    let systemMemoryUsedBytes: UInt64
    let systemMemoryTotalBytes: UInt64
    let readBytesPerSecond: Double?
    let writeBytesPerSecond: Double?
    let threadCount: Int

    static let empty = SidecarResourceSnapshot(
        cpuPercent: nil,
        systemCPUPercent: nil,
        memoryBytes: 0,
        systemMemoryUsedBytes: 0,
        systemMemoryTotalBytes: 0,
        readBytesPerSecond: nil,
        writeBytesPerSecond: nil,
        threadCount: 0
    )
}

struct SidecarProcessInfo: Hashable, Identifiable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let name: String
    let startedAt: Date
    let cpuPercent: Double?
    let memoryBytes: UInt64
    let threadCount: Int

    var id: Int32 { pid }
}

struct SidecarListeningPort: Identifiable, Hashable, Sendable {
    let pid: Int32
    let address: String
    let port: UInt16

    var id: String { "\(pid):\(address):\(port)" }
}

/// Reads process, resource, and socket metadata through libproc.
///
/// This actor keeps all blocking system inspection off the main actor. It
/// inspects only the bounded foreground process tree plus its shell parent; it
/// never scans every process or socket on the machine.
actor SidecarProcessService {
    static let shared = SidecarProcessService()

    private static let processCacheDuration: TimeInterval = 2
    private static let portCacheDuration: TimeInterval = 4
    private static let samplerCacheDuration: TimeInterval = 300
    private static let systemCacheDuration: TimeInterval = 0.5

    private var processCache: SidecarProcessTreeCache?
    private var portCache: [SidecarProcessIdentity: SidecarPortCacheEntry] = [:]
    private var resourceSamplers: [SidecarProcessIdentity: SidecarResourceSampler] = [:]
    private var systemResourceSampler = SidecarSystemResourceSampler()
    private var systemResourceCache: SidecarSystemResourceCache?

    func snapshot(
        foregroundPID: Int?,
        includeResources: Bool = true
    ) -> SidecarProcessSnapshot {
        guard let foregroundPID, let rootPID = Int32(exactly: foregroundPID) else {
            return .empty
        }

        guard let root = processDescriptor(pid: rootPID) else { return .empty }
        let now = Date()
        let rootIdentity = SidecarProcessIdentity(root)
        let rootChildren = childPIDs(of: root.pid)
        let descriptors: [SidecarProcessDescriptor]
        if let cached = processCache,
           cached.root == rootIdentity,
           cached.rootChildren == rootChildren,
           now.timeIntervalSince(cached.loadedAt)
            < Self.processCacheDuration {
            descriptors = cached.processes
        } else {
            var refreshed = processTree(
                root: root,
                rootChildren: rootChildren,
                limit: 64
            )
            if !isShell(root.name),
               !refreshed.contains(where: { $0.pid == root.parentPID }),
               let parent = processDescriptor(pid: root.parentPID),
               isShell(parent.name) {
                refreshed.append(parent)
            }
            descriptors = refreshed
            processCache = .init(
                root: rootIdentity,
                rootChildren: rootChildren,
                processes: refreshed,
                loadedAt: now
            )
        }

        let sampledAt = ProcessInfo.processInfo.systemUptime
        var resourceCollection = SidecarResourceCollection.empty
        if includeResources {
            resourceCollection = collectResources(
                for: descriptors,
                sampledAt: sampledAt
            )
            let systemResources = collectSystemResources(
                sampledAt: sampledAt
            )
            let processResources = resourceCollection.snapshot
            resourceCollection.snapshot = SidecarResourceSnapshot(
                cpuPercent: processResources.cpuPercent,
                systemCPUPercent: systemResources.cpuPercent,
                memoryBytes: processResources.memoryBytes,
                systemMemoryUsedBytes: systemResources.memoryUsedBytes,
                systemMemoryTotalBytes: systemResources.memoryTotalBytes,
                readBytesPerSecond: processResources.readBytesPerSecond,
                writeBytesPerSecond: processResources.writeBytesPerSecond,
                threadCount: processResources.threadCount
            )
        } else if let root = descriptors.first {
            resourceSamplers.removeValue(
                forKey: SidecarProcessIdentity(root)
            )
        }
        let processes = descriptors.map { descriptor in
            let usage = resourceCollection.processes[
                SidecarProcessIdentity(descriptor)
            ] ?? .empty
            return SidecarProcessInfo(
                pid: descriptor.pid,
                parentPID: descriptor.parentPID,
                name: descriptor.name,
                startedAt: descriptor.startedAt,
                cpuPercent: usage.cpuPercent,
                memoryBytes: usage.memoryBytes,
                threadCount: usage.threadCount
            )
        }

        var ports = Set<SidecarListeningPort>()
        for process in descriptors {
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
        let activeIdentities = Set(descriptors.map(SidecarProcessIdentity.init))
        portCache = portCache.filter { activeIdentities.contains($0.key) }

        return SidecarProcessSnapshot(
            processes: processes,
            listeningPorts: ports.sorted {
                if $0.port != $1.port { return $0.port < $1.port }
                if $0.address != $1.address { return $0.address < $1.address }
                return $0.pid < $1.pid
            },
            resources: resourceCollection.snapshot
        )
    }

    private func collectResources(
        for processes: [SidecarProcessDescriptor],
        sampledAt: TimeInterval
    ) -> SidecarResourceCollection {
        let samples = processes.compactMap(resourceSample)
        guard let root = processes.first else { return .empty }
        let samplerKey = SidecarProcessIdentity(root)

        let cachedSampler = resourceSamplers[samplerKey]
        var sampler = if let cachedSampler,
                         sampledAt - cachedSampler.lastAccessTime
                         < Self.samplerCacheDuration {
            cachedSampler
        } else {
            SidecarResourceSampler()
        }
        let result = sampler.snapshot(
            samples: samples,
            sampledAt: sampledAt,
            processorCount: ProcessInfo.processInfo.activeProcessorCount
        )
        resourceSamplers[samplerKey] = sampler
        resourceSamplers = resourceSamplers.filter {
            sampledAt - $0.value.lastAccessTime < Self.samplerCacheDuration
        }
        return result
    }

    private func processTree(
        root: SidecarProcessDescriptor,
        rootChildren: [Int32],
        limit: Int
    ) -> [SidecarProcessDescriptor] {
        var pending = rootChildren
        var seen: Set<Int32> = [root.pid]
        var result = [root]

        while let pid = pending.first, result.count < limit {
            guard !Task.isCancelled else { return [] }
            pending.removeFirst()
            guard seen.insert(pid).inserted else { continue }
            if let info = processDescriptor(pid: pid) {
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

    private func processDescriptor(pid: Int32) -> SidecarProcessDescriptor? {
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

        return SidecarProcessDescriptor(
            pid: pid,
            parentPID: Int32(bitPattern: info.pbi_ppid),
            name: name,
            startedAt: Date(timeIntervalSince1970: start)
        )
    }

    private func resourceSample(
        process: SidecarProcessDescriptor
    ) -> SidecarRawResourceSample? {
        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: 1
            ) {
                proc_pid_rusage(process.pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard usageResult == 0 else { return nil }

        var task = proc_taskinfo()
        let taskByteCount = withUnsafeMutablePointer(to: &task) {
            proc_pidinfo(
                process.pid,
                PROC_PIDTASKINFO,
                0,
                $0,
                Int32(MemoryLayout<proc_taskinfo>.size)
            )
        }
        let threadCount = taskByteCount == MemoryLayout<proc_taskinfo>.size
            ? max(0, Int(task.pti_threadnum))
            : 0

        return SidecarRawResourceSample(
            identity: SidecarProcessIdentity(process),
            cpuTimeNanoseconds: usage.ri_user_time &+ usage.ri_system_time,
            memoryBytes: usage.ri_phys_footprint,
            readBytes: usage.ri_diskio_bytesread,
            writeBytes: usage.ri_diskio_byteswritten,
            threadCount: threadCount
        )
    }

    private func collectSystemResources(
        sampledAt: TimeInterval
    ) -> SidecarSystemResourceSnapshot {
        if let cached = systemResourceCache,
           sampledAt - cached.sampledAt < Self.systemCacheDuration {
            return cached.snapshot
        }
        if let cached = systemResourceCache,
           sampledAt - cached.sampledAt > 3 {
            systemResourceSampler = SidecarSystemResourceSampler()
        }

        let rawSample = SidecarRawSystemResourceSample(
            cpuTicks: systemCPUTicks(),
            memory: systemMemoryUsage()
        )
        let snapshot = systemResourceSampler.snapshot(sample: rawSample)
        systemResourceCache = SidecarSystemResourceCache(
            snapshot: snapshot,
            sampledAt: sampledAt
        )
        return snapshot
    }

    private func systemCPUTicks() -> SidecarSystemCPUTicks? {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )
        guard result == KERN_SUCCESS, let processorInfo else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: processorInfo)),
                vm_size_t(
                    Int(processorInfoCount)
                        * MemoryLayout<integer_t>.stride
                )
            )
        }

        let values = UnsafeBufferPointer(
            start: processorInfo,
            count: Int(processorInfoCount)
        )
        let valuesPerProcessor = Int(CPU_STATE_MAX)
        guard processorCount > 0,
              values.count >= Int(processorCount) * valuesPerProcessor else {
            return nil
        }

        var total: UInt64 = 0
        var idle: UInt64 = 0
        for processor in 0..<Int(processorCount) {
            let offset = processor * valuesPerProcessor
            for state in 0..<valuesPerProcessor {
                total = saturatingAdd(
                    total,
                    UInt64(values[offset + state])
                )
            }
            idle = saturatingAdd(
                idle,
                UInt64(values[offset + Int(CPU_STATE_IDLE)])
            )
        }
        return SidecarSystemCPUTicks(total: total, idle: idle)
    }

    private func systemMemoryUsage() -> SidecarSystemMemoryUsage? {
        var statistics = vm_statistics64()
        var statisticsCount = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size
                / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(statisticsCount)
            ) {
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    $0,
                    &statisticsCount
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            return nil
        }

        let activePages = UInt64(statistics.active_count)
        let wiredPages = UInt64(statistics.wire_count)
        let usedBytes = saturatingMultiply(
            saturatingAdd(activePages, wiredPages),
            UInt64(pageSize)
        )
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        return SidecarSystemMemoryUsage(
            usedBytes: min(usedBytes, totalBytes),
            totalBytes: totalBytes
        )
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }

    private func saturatingMultiply(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? .max : result.partialValue
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

            let port = UInt16(
                bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)
            )
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
            if inet_ntop(
                AF_INET,
                &address,
                &buffer,
                socklen_t(INET_ADDRSTRLEN)
            ) != nil {
                return String(cString: buffer)
            }
        }

        if info.insi_vflag & UInt8(INI_IPV6) != 0 {
            var address = info.insi_laddr.ina_6
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if inet_ntop(
                AF_INET6,
                &address,
                &buffer,
                socklen_t(INET6_ADDRSTRLEN)
            ) != nil {
                return String(cString: buffer)
            }
        }

        return "*"
    }
}

private struct SidecarProcessDescriptor {
    let pid: Int32
    let parentPID: Int32
    let name: String
    let startedAt: Date
}

private struct SidecarProcessIdentity: Hashable {
    let pid: Int32
    let startedAt: Date

    init(_ process: SidecarProcessDescriptor) {
        self.pid = process.pid
        self.startedAt = process.startedAt
    }
}

private struct SidecarRawResourceSample {
    let identity: SidecarProcessIdentity
    let cpuTimeNanoseconds: UInt64
    let memoryBytes: UInt64
    let readBytes: UInt64
    let writeBytes: UInt64
    let threadCount: Int
}

private struct SidecarProcessResourceUsage {
    let cpuPercent: Double?
    let memoryBytes: UInt64
    let readBytesPerSecond: Double?
    let writeBytesPerSecond: Double?
    let threadCount: Int

    static let empty = SidecarProcessResourceUsage(
        cpuPercent: nil,
        memoryBytes: 0,
        readBytesPerSecond: nil,
        writeBytesPerSecond: nil,
        threadCount: 0
    )
}

private struct SidecarResourceCollection {
    var snapshot: SidecarResourceSnapshot
    let processes: [SidecarProcessIdentity: SidecarProcessResourceUsage]

    static let empty = SidecarResourceCollection(
        snapshot: .empty,
        processes: [:]
    )
}

private struct SidecarResourceSampler {
    private var previousSamples: [SidecarProcessIdentity: SidecarRawResourceSample] = [:]
    private var previousSampleTime: TimeInterval?
    private(set) var lastAccessTime: TimeInterval = 0

    mutating func snapshot(
        samples: [SidecarRawResourceSample],
        sampledAt: TimeInterval,
        processorCount: Int
    ) -> SidecarResourceCollection {
        let elapsed = previousSampleTime.map { sampledAt - $0 }
        let processorCount = max(1, processorCount)
        var processUsage: [SidecarProcessIdentity: SidecarProcessResourceUsage] = [:]
        var cpuPercent: Double?
        var memoryBytes: UInt64 = 0
        var readBytesPerSecond: Double?
        var writeBytesPerSecond: Double?
        var threadCount = 0

        for sample in samples {
            let usage = usage(
                for: sample,
                previous: previousSamples[sample.identity],
                elapsed: elapsed,
                processorCount: processorCount
            )
            processUsage[sample.identity] = usage
            memoryBytes = saturatingAdd(memoryBytes, usage.memoryBytes)
            threadCount += usage.threadCount
            cpuPercent = sum(cpuPercent, usage.cpuPercent)
            readBytesPerSecond = sum(
                readBytesPerSecond,
                usage.readBytesPerSecond
            )
            writeBytesPerSecond = sum(
                writeBytesPerSecond,
                usage.writeBytesPerSecond
            )
        }

        previousSamples = Dictionary(
            uniqueKeysWithValues: samples.map { ($0.identity, $0) }
        )
        previousSampleTime = sampledAt
        lastAccessTime = sampledAt

        return SidecarResourceCollection(
            snapshot: SidecarResourceSnapshot(
                cpuPercent: cpuPercent.map { min(max($0, 0), 100) },
                systemCPUPercent: nil,
                memoryBytes: memoryBytes,
                systemMemoryUsedBytes: 0,
                systemMemoryTotalBytes: 0,
                readBytesPerSecond: readBytesPerSecond,
                writeBytesPerSecond: writeBytesPerSecond,
                threadCount: threadCount
            ),
            processes: processUsage
        )
    }

    private func usage(
        for sample: SidecarRawResourceSample,
        previous: SidecarRawResourceSample?,
        elapsed: TimeInterval?,
        processorCount: Int
    ) -> SidecarProcessResourceUsage {
        guard let previous,
              let elapsed,
              elapsed > 0,
              sample.cpuTimeNanoseconds >= previous.cpuTimeNanoseconds,
              sample.readBytes >= previous.readBytes,
              sample.writeBytes >= previous.writeBytes else {
            return SidecarProcessResourceUsage(
                cpuPercent: nil,
                memoryBytes: sample.memoryBytes,
                readBytesPerSecond: nil,
                writeBytesPerSecond: nil,
                threadCount: sample.threadCount
            )
        }

        let cpuNanoseconds = sample.cpuTimeNanoseconds
            - previous.cpuTimeNanoseconds
        let cpuPercent = Double(cpuNanoseconds)
            / 1_000_000_000
            / elapsed
            / Double(processorCount)
            * 100

        return SidecarProcessResourceUsage(
            cpuPercent: min(max(cpuPercent, 0), 100),
            memoryBytes: sample.memoryBytes,
            readBytesPerSecond: Double(sample.readBytes - previous.readBytes)
                / elapsed,
            writeBytesPerSecond: Double(sample.writeBytes - previous.writeBytes)
                / elapsed,
            threadCount: sample.threadCount
        )
    }

    private func sum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case (.none, .none):
            nil
        case (.some(let lhs), .none):
            lhs
        case (.none, .some(let rhs)):
            rhs
        case (.some(let lhs), .some(let rhs)):
            lhs + rhs
        }
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}

private struct SidecarSystemCPUTicks {
    let total: UInt64
    let idle: UInt64
}

private struct SidecarSystemMemoryUsage {
    let usedBytes: UInt64
    let totalBytes: UInt64
}

private struct SidecarRawSystemResourceSample {
    let cpuTicks: SidecarSystemCPUTicks?
    let memory: SidecarSystemMemoryUsage?
}

private struct SidecarSystemResourceSnapshot {
    let cpuPercent: Double?
    let memoryUsedBytes: UInt64
    let memoryTotalBytes: UInt64
}

private struct SidecarSystemResourceSampler {
    private var previousCPUTicks: SidecarSystemCPUTicks?

    mutating func snapshot(
        sample: SidecarRawSystemResourceSample
    ) -> SidecarSystemResourceSnapshot {
        let cpuPercent = cpuPercent(
            current: sample.cpuTicks,
            previous: previousCPUTicks
        )
        if let cpuTicks = sample.cpuTicks {
            previousCPUTicks = cpuTicks
        }

        return SidecarSystemResourceSnapshot(
            cpuPercent: cpuPercent,
            memoryUsedBytes: sample.memory?.usedBytes ?? 0,
            memoryTotalBytes: sample.memory?.totalBytes ?? 0
        )
    }

    private func cpuPercent(
        current: SidecarSystemCPUTicks?,
        previous: SidecarSystemCPUTicks?
    ) -> Double? {
        guard let current,
              let previous,
              current.total > previous.total,
              current.idle >= previous.idle else {
            return nil
        }

        let totalDelta = current.total - previous.total
        let idleDelta = min(current.idle - previous.idle, totalDelta)
        return min(
            max(Double(totalDelta - idleDelta) / Double(totalDelta) * 100, 0),
            100
        )
    }
}

private struct SidecarSystemResourceCache {
    let snapshot: SidecarSystemResourceSnapshot
    let sampledAt: TimeInterval
}

private struct SidecarProcessTreeCache {
    let root: SidecarProcessIdentity
    let rootChildren: [Int32]
    let processes: [SidecarProcessDescriptor]
    let loadedAt: Date
}

private struct SidecarPortCacheEntry {
    let ports: Set<SidecarListeningPort>
    let loadedAt: Date
}
