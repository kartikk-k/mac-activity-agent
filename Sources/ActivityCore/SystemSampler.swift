import Foundation
import Darwin
import IOKit
import IOKit.ps

public struct SystemSnapshot: Codable, Sendable {
    public var timestamp: Date
    public var cpuPercent: Double
    public var memoryTotal: UInt64
    public var memoryUsed: UInt64
    public var memoryWired: UInt64
    public var memoryCompressed: UInt64
    public var memoryCached: UInt64
    public var swapUsed: UInt64
    public var networkReceivedBytes: UInt64
    public var networkSentBytes: UInt64
    public var diskReadBytes: UInt64
    public var diskWriteBytes: UInt64
    public var batteryPercent: Double?
    public var isCharging: Bool
    public var thermalState: String
    public var uptime: TimeInterval
    /// Best-effort driver registry telemetry; nil when the driver does not expose it.
    public var gpuPercent: Double? = nil
    public var temperatureCelsius: Double? = nil
}

/// One instance per sampling queue. Counters are differenced, never subprocess-polled.
public final class SystemSampler {
    private let hostPort = mach_host_self()
    private var previousCPU: [UInt64]?
    private var previousCounters: (time: TimeInterval, rx: UInt64, tx: UInt64, read: UInt64, write: UInt64)?
    public init() {}
    deinit { mach_port_deallocate(mach_task_self_, hostPort) }
    public func sample() -> SystemSnapshot {
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        let network = networkCounters(), disk = diskCounters()
        let old = previousCounters
        let elapsed = old.map { uptime - $0.time } ?? 0
        func rate(_ current: UInt64, _ prior: UInt64?) -> UInt64 {
            guard let prior, elapsed > 0, current >= prior else { return 0 }
            return UInt64(Double(current - prior) / elapsed)
        }
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        let page = UInt64(vm_kernel_page_size)
        let wired = result == KERN_SUCCESS ? UInt64(vm.wire_count) * page : 0
        let compressed = result == KERN_SUCCESS ? UInt64(vm.compressor_page_count) * page : 0
        let cached = result == KERN_SUCCESS ? (UInt64(vm.external_page_count) + UInt64(vm.purgeable_count)) * page : 0
        let used = result == KERN_SUCCESS ? min(total, (UInt64(vm.active_count) + UInt64(vm.inactive_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page - min((UInt64(vm.active_count) + UInt64(vm.inactive_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page, cached)) : 0
        var swap = xsw_usage(), swapSize = MemoryLayout<xsw_usage>.size
        _ = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        let battery = batteryStatus()
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "Nominal"
        case .fair: thermal = "Fair"
        case .serious: thermal = "Serious"
        case .critical: thermal = "Critical"
        @unknown default: thermal = "Unknown"
        }
        var snapshot = SystemSnapshot(timestamp: now, cpuPercent: cpuUsage(), memoryTotal: total, memoryUsed: used, memoryWired: wired, memoryCompressed: compressed, memoryCached: cached, swapUsed: swap.xsu_used, networkReceivedBytes: rate(network.0, old?.rx), networkSentBytes: rate(network.1, old?.tx), diskReadBytes: rate(disk.0, old?.read), diskWriteBytes: rate(disk.1, old?.write), batteryPercent: battery.0, isCharging: battery.1, thermalState: thermal, uptime: uptime)
        snapshot.gpuPercent = gpuUtilization()
        previousCounters = (uptime, network.0, network.1, disk.0, disk.1)
        return snapshot
    }
    private func cpuUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3].map(UInt64.init)
        defer { previousCPU = ticks }
        guard let previousCPU else { return 0 }
        let differences = zip(ticks, previousCPU).map { $0 >= $1 ? $0 - $1 : 0 }
        let total = differences.reduce(0, +)
        return total == 0 ? 0 : Double(total - differences[2]) / Double(total) * 100
    }
    private func networkCounters() -> (UInt64, UInt64) {
        // Routing interface messages expose 64-bit byte counters. if_data from
        // getifaddrs is only 32-bit and wraps during long/high-throughput sessions.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: MemoryLayout<if_msghdr2>.alignment)
        defer { buffer.deallocate() }
        guard sysctl(&mib, u_int(mib.count), buffer, &length, nil, 0) == 0 else { return (0, 0) }
        var offset = 0, rx: UInt64 = 0, tx: UInt64 = 0
        while offset + MemoryLayout<if_msghdr>.size <= length {
            let header = buffer.advanced(by: offset).loadUnaligned(as: if_msghdr.self)
            let size = Int(header.ifm_msglen)
            guard size > 0, offset + size <= length else { break }
            if header.ifm_type == RTM_IFINFO2, size >= MemoryLayout<if_msghdr2>.size {
                let info = buffer.advanced(by: offset).loadUnaligned(as: if_msghdr2.self)
                if info.ifm_flags & IFF_LOOPBACK == 0 {
                    rx &+= info.ifm_data.ifi_ibytes
                    tx &+= info.ifm_data.ifi_obytes
                }
            }
            offset += size
        }
        return (rx, tx)
    }
    private func diskCounters() -> (UInt64, UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let raw = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let stats = raw as? [String: Any] {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
        }
        return (read, write)
    }
    private func gpuUtilization() -> Double? {
        // The IOKit read API is public; PerformanceStatistics keys are driver-specific,
        // so availability is optional. Never infer idle (0%) from a missing property.
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var peak: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let raw = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let stats = raw as? [String: Any],
                  let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue,
                  value.isFinite, (0...100).contains(value) else { continue }
            // On multi-GPU Macs report the busiest device, not an invalid sum.
            peak = max(peak ?? value, value)
        }
        return peak
    }
    private func batteryStatus() -> (Double?, Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return (Double(current) / Double(maximum) * 100, description[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return (nil, false)
    }
}
