import Foundation

public struct AgentUsageWindow: Sendable {
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?
}

public struct AgentUsageSnapshot: Sendable {
    public let provider: AgentProvider
    public let observedAt: Date
    public let sessionTokens: Int?
    public let primary: AgentUsageWindow?
    public let secondary: AgentUsageWindow?
    public let sourceDescription: String
}

public struct AgentLocalTokenSummary: Sendable {
    public let provider: AgentProvider
    public let todayTokens: Int
    public let weekTokens: Int
    public let observedMessages: Int
    public let newestEventAt: Date
    public let sampledAt: Date
    public let isPartial: Bool
    public let sourceDescription: String
}

public struct AgentTokenObservation: Sendable {
    public let messageID: String
    public let timestamp: Date
    public let tokens: Int
}

/// Retains only usage metadata from bounded log reads. Conversation text is never
/// stored or returned; credential files are never opened.
/// The returned values are historical local observations, not a live account balance.
public actor AgentUsageService {
    private var lastRead = Date.distantPast
    private var cached: AgentUsageSnapshot?
    private var fileCache: [String: (modified: Date, snapshot: AgentUsageSnapshot?)] = [:]
    private var claudeLastRead = Date.distantPast
    private var claudeCached: AgentLocalTokenSummary?
    private var claudeFiles: [String: (offset: UInt64, observations: [String: AgentTokenObservation])] = [:]
    public init() {}

    public func claudeUsage(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AgentLocalTokenSummary? {
        guard Date().timeIntervalSince(claudeLastRead) >= 30 else { return claudeCached }
        claudeLastRead = Date()
        let base = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey, .isRegularFileKey]
        let directories = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: Array(keys))) ?? []
        var candidates: [(URL, Date)] = []
        for directory in directories.prefix(64) {
            guard (try? directory.resourceValues(forKeys: keys).isDirectory) == true else { continue }
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
            for file in files.prefix(128) where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                candidates.append((file, values.contentModificationDate ?? .distantPast))
            }
        }
        let selected = candidates.sorted { $0.1 > $1.1 }.prefix(8)
        let paths = Set(selected.map { $0.0.path })
        claudeFiles = claudeFiles.filter { paths.contains($0.key) }
        for (url, _) in selected {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd() else { continue }
            var entry = claudeFiles[url.path] ?? (offset: size > 524_288 ? size - 524_288 : 0, observations: [:])
            if size < entry.offset { entry = (0, [:]) }
            if size == entry.offset { continue }
            let start = max(entry.offset, size > 524_288 ? size - 524_288 : 0)
            try? handle.seek(toOffset: start)
            guard let data = try? handle.read(upToCount: 524_288), let lastNewline = data.lastIndex(of: 10) else { continue }
            // Advance only through complete lines; partial writes are retried next refresh.
            entry.offset = start + UInt64(lastNewline + 1)
            let text = String(decoding: data[...lastNewline], as: UTF8.self)
            for observation in Self.parseClaude(text) {
                if let previous = entry.observations[observation.messageID], previous.tokens >= observation.tokens { continue }
                entry.observations[observation.messageID] = observation
            }
            let oldest = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
            entry.observations = entry.observations.filter { $0.value.timestamp >= oldest }
            if entry.observations.count > 5000 {
                entry.observations = Dictionary(uniqueKeysWithValues: entry.observations.values.sorted { $0.timestamp > $1.timestamp }.prefix(5000).map { ($0.messageID, $0) })
            }
            claudeFiles[url.path] = entry
        }
        // Deduplicate message IDs across logs as well (resumed sessions may repeat messages).
        var observations: [String: AgentTokenObservation] = [:]
        for entry in claudeFiles.values {
            for observation in entry.observations.values where observation.tokens > (observations[observation.messageID]?.tokens ?? -1) { observations[observation.messageID] = observation }
        }
        guard let newest = observations.values.map(\.timestamp).max() else { claudeCached = nil; return nil }
        let today = Calendar.current.startOfDay(for: Date())
        let week = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        claudeCached = AgentLocalTokenSummary(provider: .claude,
            todayTokens: observations.values.filter { $0.timestamp >= today }.reduce(0) { $0 + $1.tokens },
            weekTokens: observations.values.filter { $0.timestamp >= week }.reduce(0) { $0 + $1.tokens },
            observedMessages: observations.count, newestEventAt: newest, sampledAt: Date(), isPartial: true,
            sourceDescription: "Observed tokens in recent local logs; partial totals, including cache tokens")
        return claudeCached
    }

    public static func parseClaude(_ jsonLines: String) -> [AgentTokenObservation] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainISO = ISO8601DateFormatter()
        return jsonLines.split(separator: "\n").compactMap { line in
            guard line.contains("\"usage\""), let data = String(line).data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["type"] as? String == "assistant",
                  let message = root["message"] as? [String: Any], let id = message["id"] as? String,
                  let usage = message["usage"] as? [String: Any], let timestamp = root["timestamp"] as? String,
                  let date = iso.date(from: timestamp) ?? plainISO.date(from: timestamp) else { return nil }
            let keys = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            let counts = keys.compactMap { usage[$0] as? Int }
            guard !counts.isEmpty, counts.allSatisfy({ (0...1_000_000_000).contains($0) }) else { return nil }
            return AgentTokenObservation(messageID: id, timestamp: date, tokens: counts.reduce(0, +))
        }
    }

    public func codexUsage(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AgentUsageSnapshot? {
        guard Date().timeIntervalSince(lastRead) >= 30 else { return cached }
        lastRead = Date()
        let base = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        var candidates: [(URL, Date)] = []
        // Bounded to two daily directories and at most eight recent files.
        for day in 0...1 {
            let directory = base.appendingPathComponent(formatter.string(from: Date().addingTimeInterval(Double(-day) * 86400)))
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
                candidates.append((file, values.contentModificationDate ?? .distantPast))
            }
        }
        var observations: [AgentUsageSnapshot] = []
        let selected = Array(candidates.sorted(by: { $0.1 > $1.1 }).prefix(8))
        let paths = Set(selected.map { $0.0.path })
        fileCache = fileCache.filter { paths.contains($0.key) }
        for (url, modified) in selected {
            if let entry = fileCache[url.path], entry.modified == modified {
                if let snapshot = entry.snapshot { observations.append(snapshot) }
                continue
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd() else { continue }
            try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
            guard let data = try? handle.read(upToCount: 262_144), let tail = String(data: data, encoding: .utf8) else { continue }
            let observation = Self.parse(tail)
            fileCache[url.path] = (modified, observation)
            if let observation { observations.append(observation) }
        }
        cached = observations.max(by: { $0.observedAt < $1.observedAt })
        return cached
    }

    public static func parse(_ jsonLines: String) -> AgentUsageSnapshot? {
        var latest: AgentUsageSnapshot?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainISO = ISO8601DateFormatter()
        for line in jsonLines.split(separator: "\n") {
            guard line.contains("token_count"), let data = String(line).data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["type"] as? String == "event_msg",
                  let payload = root["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                  let timestamp = root["timestamp"] as? String,
                  let date = iso.date(from: timestamp) ?? plainISO.date(from: timestamp) else { continue }
            let info = payload["info"] as? [String: Any]
            let totals = info?["total_token_usage"] as? [String: Any]
            let limits = payload["rate_limits"] as? [String: Any]
            func window(_ key: String) -> AgentUsageWindow? {
                guard let values = limits?[key] as? [String: Any], let percent = values["used_percent"] as? Double,
                      percent.isFinite, (0...100).contains(percent) else { return nil }
                return AgentUsageWindow(usedPercent: percent, windowMinutes: values["window_minutes"] as? Int,
                    resetsAt: (values["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) })
            }
            let snapshot = AgentUsageSnapshot(provider: .codex, observedAt: date,
                sessionTokens: totals?["total_tokens"] as? Int, primary: window("primary"), secondary: window("secondary"),
                sourceDescription: "Latest local Codex session observation")
            if latest == nil || date >= latest!.observedAt { latest = snapshot }
        }
        return latest
    }
}
