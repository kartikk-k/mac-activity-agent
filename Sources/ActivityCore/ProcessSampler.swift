import Foundation
import CActivity

/// Call from one serial executor. CPU uses monotonic deltas; metadata is cached by
/// PID plus birth time, so repeated samples avoid thousands of path lookups.
public final class ProcessSampler {
    private struct Cached {
        var startSec: UInt64
        var startUsec: UInt64
        var cpu: UInt64
        var sampleTime: TimeInterval
        var path: String
        var bundle: String?
        var cwd: String?
        var metadataTime: TimeInterval
    }
    private var cache: [Int32: Cached] = [:]
    private var pids = [Int32](repeating: 0, count: 2048)
    public init() {}
    public static func cpuPercentage(previousCPU: UInt64, currentCPU: UInt64, elapsed: TimeInterval, sameProcess: Bool) -> Double {
        guard sameProcess, elapsed > 0, currentCPU >= previousCPU else { return 0 }
        return Double(currentCPU - previousCPU) / (elapsed * 1_000_000_000) * 100
    }
    public func sample() -> [ProcessRecord] {
        var bytes = activity_list_pids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        if bytes >= pids.count * MemoryLayout<Int32>.stride {
            pids = [Int32](repeating: 0, count: max(pids.count * 2, Int(activity_list_pids(nil, 0)) / 4 + 512))
            bytes = activity_list_pids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        }
        guard bytes > 0 else { return [] }
        let now = ProcessInfo.processInfo.systemUptime
        var next: [Int32: Cached] = [:]
        var records: [ProcessRecord] = []
        records.reserveCapacity(Int(bytes) / 4)
        for pid in pids.prefix(min(pids.count, Int(bytes) / 4)) where pid > 0 {
            var metrics = ActivityProcessMetrics()
            guard activity_read_process(pid, &metrics) != 0 else { continue }
            let previous = cache[pid]
            let same = previous?.startSec == metrics.start_sec && previous?.startUsec == metrics.start_usec
            var cached: Cached
            if same, let previous { cached = previous }
            else {
                var pathBuffer = [CChar](repeating: 0, count: 4096)
                let path = activity_process_path(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 ? String(cString: pathBuffer) : ""
                cached = Cached(startSec: metrics.start_sec, startUsec: metrics.start_usec, cpu: 0, sampleTime: now, path: path, bundle: ProcessGrouper.outerApplicationPath(path), cwd: nil, metadataTime: -.infinity)
            }
            // CWD is useful for command-line agents. App processes do not require
            // this relatively costly query and command CWD is refreshed lazily.
            if cached.bundle == nil && now - cached.metadataTime >= 30 {
                var cwdBuffer = [CChar](repeating: 0, count: 4096)
                cached.cwd = activity_process_cwd(pid, &cwdBuffer, UInt32(cwdBuffer.count)) != 0 ? String(cString: cwdBuffer) : nil
                cached.metadataTime = now
            }
            let cpu = Self.cpuPercentage(previousCPU: cached.cpu, currentCPU: metrics.cpu_ns, elapsed: now - cached.sampleTime, sameProcess: same)
            let name = withUnsafePointer(to: &metrics.name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            records.append(ProcessRecord(pid: pid, parentPID: metrics.parent_pid, name: name.isEmpty ? "Process \(pid)" : name, executablePath: cached.path, bundlePath: cached.bundle, residentBytes: metrics.memory_bytes, cpuPercent: cpu, diskReadBytes: metrics.disk_read_bytes, diskWriteBytes: metrics.disk_write_bytes, startTime: Date(timeIntervalSince1970: Double(metrics.start_sec) + Double(metrics.start_usec) / 1_000_000), workingDirectory: cached.cwd, userID: metrics.uid, isStopped: metrics.is_stopped != 0))
            cached.cpu = metrics.cpu_ns; cached.sampleTime = now
            next[pid] = cached
        }
        cache = next
        return records
    }
}
