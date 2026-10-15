import Foundation

public struct ActivityAlert: Identifiable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case sustainedCPU, memoryGrowth, diskActivity, networkActivity }
    public var id: String
    public var title: String {
        switch kind {
        case .sustainedCPU: return "High CPU usage"
        case .memoryGrowth: return "Growing memory usage"
        case .diskActivity: return "High disk activity"
        case .networkActivity: return "High network activity"
        }
    }
    public var appID: String
    public var appName: String
    public var kind: Kind
    public var message: String
    public var timestamp: Date
}
public struct AlertConfiguration: Sendable {
    public var cpuThreshold: Double = 100
    public var cpuDuration: TimeInterval = 60
    public var memoryGrowthBytes: UInt64 = 512 * 1024 * 1024
    public var memoryWindow: TimeInterval = 300
    public var diskBytesPerSecond: UInt64 = 50 * 1024 * 1024
    public var diskDuration: TimeInterval = 30
    /// Aggregate Mac traffic; no per-app attribution is available.
    public var networkBytesPerSecond: UInt64 = 25 * 1024 * 1024
    public var networkDuration: TimeInterval = 30
    public var cooldown: TimeInterval = 900
    public init() {}
}
/// Evaluates sampled app data; never kills processes or sends notifications itself.
public final class AlertEvaluator {
    public var configuration: AlertConfiguration
    private struct State {
        var cpuSince: Date?
        var diskSince: Date?
        var previousDisk: (Date, UInt64)?
        var memory: [(Date, UInt64)] = []
        var lastAlerts: [ActivityAlert.Kind: Date] = [:]
        var lastSample: Date?
    }
    private var states: [String: State] = [:]
    private var networkSince: Date?
    private var lastNetworkAlert: Date?
    private var lastSystemSample: Date?
    public init(configuration: AlertConfiguration = AlertConfiguration()) { self.configuration = configuration }
    /// Evaluates aggregate interface traffic. It cannot identify the responsible app.
    public func evaluate(system: SystemSnapshot) -> [ActivityAlert] {
        let now = system.timestamp
        if let prior = lastSystemSample, now.timeIntervalSince(prior) > 60 || now < prior { networkSince = nil }
        lastSystemSample = now
        let total = system.networkReceivedBytes.addingReportingOverflow(system.networkSentBytes)
        guard total.overflow || total.partialValue >= configuration.networkBytesPerSecond else { networkSince = nil; return [] }
        networkSince = networkSince ?? now
        guard let since = networkSince, now.timeIntervalSince(since) >= configuration.networkDuration,
              lastNetworkAlert.map({ now.timeIntervalSince($0) >= configuration.cooldown }) ?? true else { return [] }
        lastNetworkAlert = now
        return [ActivityAlert(id: "system:network:\(now.timeIntervalSince1970)", appID: "system", appName: "This Mac", kind: .networkActivity, message: "This Mac has sustained high network traffic for \(Int(configuration.networkDuration)) seconds across its network interfaces. Per-app attribution is unavailable.", timestamp: now)]
    }
    public func evaluate(apps: [HistoryAppMetric], at now: Date = Date()) -> [ActivityAlert] {
        let active = Set(apps.map(\.id))
        states = states.filter { active.contains($0.key) }
        var alerts: [ActivityAlert] = []
        for app in apps {
            var state = states[app.id] ?? State()
            if let prior = state.lastSample, now.timeIntervalSince(prior) > 60 || now < prior {
                state.cpuSince = nil; state.diskSince = nil; state.memory.removeAll(); state.previousDisk = nil
            }
            state.lastSample = now
            state.cpuSince = app.cpuPercent >= configuration.cpuThreshold ? state.cpuSince ?? now : nil
            let disk = app.diskReadBytes.addingReportingOverflow(app.diskWriteBytes)
            let diskTotal = disk.overflow ? UInt64.max : disk.partialValue
            var diskRate: Double = 0
            if let previous = state.previousDisk, now > previous.0, diskTotal >= previous.1 {
                diskRate = Double(diskTotal - previous.1) / now.timeIntervalSince(previous.0)
            }
            state.previousDisk = (now, diskTotal)
            state.diskSince = diskRate >= Double(configuration.diskBytesPerSecond) ? state.diskSince ?? now : nil
            state.memory.append((now, app.memoryBytes))
            // Preserve the sample immediately preceding the start of the window.
            while state.memory.count > 1, state.memory[1].0 < now.addingTimeInterval(-configuration.memoryWindow) { state.memory.removeFirst() }
            // Limit memory even if an unexpected caller samples at very high frequency.
            if state.memory.count > 1000 { state.memory.removeFirst(state.memory.count - 1000) }
            func emit(_ kind: ActivityAlert.Kind, _ message: String) {
                guard state.lastAlerts[kind].map({ now.timeIntervalSince($0) >= configuration.cooldown }) ?? true else { return }
                state.lastAlerts[kind] = now
                alerts.append(ActivityAlert(id: "\(app.id):\(kind.rawValue):\(now.timeIntervalSince1970)", appID: app.id, appName: app.name, kind: kind, message: message, timestamp: now))
            }
            if let since = state.cpuSince, now.timeIntervalSince(since) >= configuration.cpuDuration {
                emit(.sustainedCPU, "\(app.name) has used at least \(Int(configuration.cpuThreshold))% CPU for \(Int(configuration.cpuDuration)) seconds.")
            }
            if let since = state.diskSince, now.timeIntervalSince(since) >= configuration.diskDuration {
                emit(.diskActivity, "\(app.name) has sustained high disk activity.")
            }
            if let baseline = state.memory.first, now.timeIntervalSince(baseline.0) >= configuration.memoryWindow,
               app.memoryBytes >= baseline.1, app.memoryBytes - baseline.1 >= configuration.memoryGrowthBytes {
                emit(.memoryGrowth, "\(app.name)'s memory grew by \(ByteCountFormatter.string(fromByteCount: Int64(clamping: app.memoryBytes - baseline.1), countStyle: .memory)) over \(Int(configuration.memoryWindow / 60)) minutes.")
            }
            states[app.id] = state
        }
        return alerts
    }
}
