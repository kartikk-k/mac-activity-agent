import Foundation

public struct CloseRecommendation: Identifiable, Sendable {
    public let groupID: String
    public let reason: String
    public let idleDuration: TimeInterval
    public var id: String { groupID }
}

/// Suggestions are based on fresh resource observations, never inferred user intent.
/// No state survives app restart and this service cannot terminate a process.
public final class RecommendationService: @unchecked Sendable {
    private struct Observation {
        var lastSeen: Date
        var quietSince: Date
        var processes: [Int32: Date]
        var diskRead: UInt64
        var diskWrite: UInt64
        var wasQuiet: Bool
    }
    private let lock = NSLock()
    private var observations: [String: Observation] = [:]
    private let minimumIdleDuration: TimeInterval
    private let minimumRunningDuration: TimeInterval
    private let maximumObservationGap: TimeInterval
    private let maximumCPUPercent: Double

    public init(minimumIdleDuration: TimeInterval = 15 * 60,
                minimumRunningDuration: TimeInterval = 60 * 60,
                maximumObservationGap: TimeInterval = 120,
                maximumCPUPercent: Double = 0.5) {
        self.minimumIdleDuration = max(1, minimumIdleDuration)
        self.minimumRunningDuration = max(1, minimumRunningDuration)
        self.maximumObservationGap = max(1, maximumObservationGap)
        self.maximumCPUPercent = max(0, maximumCPUPercent)
    }

    public func evaluate(groups: [AppGroup], frontmostBundlePath: String?, keepRunningIDs: Set<String> = [], at now: Date = Date()) -> [CloseRecommendation] {
        lock.lock()
        defer { lock.unlock() }
        let presentIDs = Set(groups.map(\.id))
        observations = observations.filter { presentIDs.contains($0.key) }
        var recommendations: [CloseRecommendation] = []
        for group in groups {
            let identities = Dictionary(group.processes.map { ($0.pid, $0.startTime) }, uniquingKeysWith: { first, _ in first })
            let read = group.diskReadBytes
            let write = group.diskWriteBytes
            let previous = observations[group.id]
            let protected = keepRunningIDs.contains(group.id) || (frontmostBundlePath != nil && group.bundlePath == frontmostBundlePath)
            let validCPU = group.processes.allSatisfy { $0.cpuPercent.isFinite && $0.cpuPercent >= 0 }
            let quiet = validCPU && group.cpuPercent <= maximumCPUPercent
            let elapsed = previous.map { now.timeIntervalSince($0.lastSeen) } ?? .infinity
            let continuous = elapsed > 0 && elapsed <= maximumObservationGap
            let unchanged = previous?.processes == identities && previous?.diskRead == read && previous?.diskWrite == write
            let since = !protected && quiet && previous?.wasQuiet == true && continuous && unchanged ? (previous?.quietSince ?? now) : now
            observations[group.id] = Observation(lastSeen: now, quietSince: since, processes: identities, diskRead: read, diskWrite: write, wasQuiet: quiet && !protected)
            guard !protected, quiet, !group.processes.isEmpty else { continue }
            let validStarts = group.processes.map(\.startTime).filter { $0 > Date(timeIntervalSince1970: 0) && $0 <= now }
            guard validStarts.count == group.processes.count, let earliestStart = validStarts.min(),
                  now.timeIntervalSince(earliestStart) >= minimumRunningDuration else { continue }
            let duration = max(0, now.timeIntervalSince(since))
            guard duration >= minimumIdleDuration else { continue }
            let minutes = Int(duration / 60)
            recommendations.append(CloseRecommendation(groupID: group.id,
                reason: "Low observed CPU and no disk changes for \(minutes) min. Review whether you still need this app before closing it.",
                idleDuration: duration))
        }
        return recommendations.sorted { $0.idleDuration > $1.idleDuration }
    }
}
