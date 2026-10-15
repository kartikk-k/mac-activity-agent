import Foundation

public struct HistoryAppMetric: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    /// Cumulative per-app disk counters, not rates.
    public var diskReadBytes: UInt64
    public var diskWriteBytes: UInt64
    public init(id: String, name: String, cpuPercent: Double, memoryBytes: UInt64, diskReadBytes: UInt64 = 0, diskWriteBytes: UInt64 = 0) {
        self.id = id; self.name = name; self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes
        self.diskReadBytes = diskReadBytes; self.diskWriteBytes = diskWriteBytes
    }
}
public struct HistorySample: Codable, Sendable, Identifiable {
    public var id: Date { system.timestamp }
    public var timestamp: Date { system.timestamp }
    public var system: SystemSnapshot
    public var apps: [HistoryAppMetric]
}
/// Use from a single sampling queue. Stores one sample/minute for 24 hours, then one/hour.
/// Data stays local. Persist at five-minute intervals and call flush when terminating.
public final class HistoryStore {
    public static let supportedRetentionDays = [30, 90, 180, 365]
    public var retentionDays: Int {
        didSet {
            guard retentionDays != oldValue else { return }
            if !Self.supportedRetentionDays.contains(retentionDays) { retentionDays = oldValue; return }
            compact(now: Date()); dirty = true; flush()
        }
    }
    public private(set) var lastError: String?
    private let fileURL: URL
    private var records: [HistorySample] = []
    private var lastFlush = Date.distantPast
    private var dirty = false
    public init(directory: URL? = nil, retentionDays: Int = 30) {
        self.retentionDays = Self.supportedRetentionDays.contains(retentionDays) ? retentionDays : 30
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ActivityAgent", isDirectory: true)
        fileURL = base.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: fileURL) {
            do { records = try JSONDecoder().decode([HistorySample].self, from: data).sorted { $0.id < $1.id }; compact(now: Date()) }
            catch { lastError = "History could not be loaded: \(error.localizedDescription)" }
        }
    }
    public func setRetentionDays(_ days: Int) {
        guard Self.supportedRetentionDays.contains(days) else { return }
        retentionDays = days
    }
    public func record(system: SystemSnapshot, apps: [HistoryAppMetric]) {
        // Handle wall clock moving backwards without duplicating or indefinitely blocking samples.
        if let last = records.last, system.timestamp.timeIntervalSince(last.id) >= 0, system.timestamp.timeIntervalSince(last.id) < 60 { return }
        records.append(HistorySample(system: system, apps: apps))
        dirty = true
        compact(now: system.timestamp)
        if system.timestamp.timeIntervalSince(lastFlush) >= 300 { flush() }
    }
    public func samples(since: Date = .distantPast) -> [HistorySample] { records.filter { $0.id >= since } }
    public func flush() {
        guard dirty else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
            lastFlush = Date(); lastError = nil; dirty = false
        } catch { lastError = "History could not be saved: \(error.localizedDescription)" }
    }
    public func clear() { records.removeAll(); dirty = true; flush() }
    private func compact(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        let recent = now.addingTimeInterval(-86400)
        var buckets: [Int64: HistorySample] = [:]
        for record in records where record.id >= cutoff && record.id <= now {
            let interval = record.id < recent ? 3600.0 : 60.0
            // Negative keys distinguish hourly buckets from minute buckets.
            let key = Int64(floor(record.id.timeIntervalSince1970 / interval)) * (interval == 3600 ? -1 : 1)
            buckets[key] = record
        }
        records = buckets.values.sorted { $0.id < $1.id }
    }
}
