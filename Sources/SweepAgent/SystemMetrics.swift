import Foundation
import Darwin

public final class SystemMetrics {
    public static let shared = SystemMetrics()

    private struct CPUTicks {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64
    }

    private let lock = NSLock()
    private var prevTicks: CPUTicks?
    private var lastCPUUsage: Double = 0

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    public func collect() -> [String: Any] {
        [
            "generatedAt": Util.nowISO(),
            "disk": diskMetrics(),
            "memory": memoryMetrics(),
            "cpu": cpuMetrics(),
            "history": historyMetrics(),
            "agent": [
                "mode": AgentConfigStore.load().mode,
                "fullDiskAccess": FullDiskAccess.hasAccess(),
            ],
        ]
    }

    private func diskMetrics() -> [String: Any] {
        let url = URL(fileURLWithPath: "/System/Volumes/Data")
        let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        let total = UInt64(max(0, values?.volumeTotalCapacity ?? 0))
        let available = UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
        let free = UInt64(max(0, values?.volumeAvailableCapacity ?? 0))
        let purgeable = available > free ? available - free : 0
        let used = total > available ? total - available : 0
        let usedPercent = total > 0 ? (Double(used) / Double(total) * 100.0) : 0

        return [
            "totalBytes": total,
            "availableBytes": available,
            "freeBytes": free,
            "purgeableBytes": purgeable,
            "usedBytes": used,
            "usedPercent": (usedPercent * 10).rounded() / 10,
        ]
    }

    private func memoryMetrics() -> [String: Any] {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            return [
                "totalBytes": total,
                "usedBytes": UInt64(0),
                "activeBytes": UInt64(0),
                "wiredBytes": UInt64(0),
                "compressedBytes": UInt64(0),
                "freeBytes": total,
                "usedPercent": 0.0,
            ]
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) &* pageSize
        let wired = UInt64(stats.wire_count) &* pageSize
        let compressed = UInt64(stats.compressor_page_count) &* pageSize
        let used = min(total, active &+ wired &+ compressed)
        let free = total > used ? total - used : 0
        let pct = total > 0 ? (Double(used) / Double(total) * 100.0) : 0

        return [
            "totalBytes": total,
            "usedBytes": used,
            "activeBytes": active,
            "wiredBytes": wired,
            "compressedBytes": compressed,
            "freeBytes": free,
            "usedPercent": (pct * 10).rounded() / 10,
        ]
    }

    private func cpuMetrics() -> [String: Any] {
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0

        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &numCpuInfo
        )

        var usagePct = 0.0
        if kr == KERN_SUCCESS, let info = cpuInfo {
            var user: UInt64 = 0
            var system: UInt64 = 0
            var idle: UInt64 = 0
            var nice: UInt64 = 0

            let stride = Int(CPU_STATE_MAX)
            for i in 0..<Int(cpuCount) {
                let base = i * stride
                user &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
                system &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
                idle &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
                nice &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            }

            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(Int(numCpuInfo) * MemoryLayout<integer_t>.stride)
            )

            let current = CPUTicks(user: user, system: system, idle: idle, nice: nice)
            lock.lock()
            if let prev = prevTicks {
                let du = current.user >= prev.user ? current.user - prev.user : 0
                let ds = current.system >= prev.system ? current.system - prev.system : 0
                let di = current.idle >= prev.idle ? current.idle - prev.idle : 0
                let dn = current.nice >= prev.nice ? current.nice - prev.nice : 0
                let totalDelta = du + ds + di + dn
                if totalDelta > 0 {
                    lastCPUUsage = Double(du + ds + dn) / Double(totalDelta) * 100.0
                }
            } else {
                let totalAll = user + system + idle + nice
                if totalAll > 0 {
                    lastCPUUsage = Double(user + system + nice) / Double(totalAll) * 100.0
                }
            }
            prevTicks = current
            usagePct = lastCPUUsage
            lock.unlock()
        }

        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)

        return [
            "usagePercent": (usagePct * 10).rounded() / 10,
            "load1": (loads[0] * 100).rounded() / 100,
            "load5": (loads[1] * 100).rounded() / 100,
            "cores": ProcessInfo.processInfo.activeProcessorCount,
        ]
    }

    private func historyMetrics() -> [String: Any] {
        let allOps = OperationLog.summaries()
        let totalCleaned = allOps.reduce(UInt64(0)) { $0 &+ $1.bytes }
        let totalMoved = allOps.reduce(0) { $0 + $1.okCount }

        let recent = allOps.suffix(12).map { op -> [String: Any] in
            [
                "id": op.id,
                "bytes": op.bytes,
                "okCount": op.okCount,
                "createdAt": op.createdAt,
            ]
        }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "MM-dd"

        var dayTotals: [Date: (bytes: UInt64, ops: Int)] = [:]
        for op in allOps {
            guard let date = Self.isoFormatter.date(from: op.createdAt) else { continue }
            let day = cal.startOfDay(for: date)
            var cur = dayTotals[day] ?? (0, 0)
            cur.bytes &+= op.bytes
            cur.ops += 1
            dayTotals[day] = cur
        }

        var daily: [[String: Any]] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            if let day = cal.date(byAdding: .day, value: -offset, to: today) {
                let stats = dayTotals[day] ?? (0, 0)
                daily.append([
                    "label": dayFmt.string(from: day),
                    "bytes": stats.bytes,
                    "ops": stats.ops,
                ])
            }
        }

        return [
            "totalCleanedBytes": totalCleaned,
            "totalOperations": allOps.count,
            "totalMovedItems": totalMoved,
            "recentOps": Array(recent),
            "daily": daily,
        ]
    }
}
