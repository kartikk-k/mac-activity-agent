import Foundation
import Darwin

public enum AgentProvider: String, CaseIterable, Sendable, Codable {
    case claude, codex, gemini, copilot, cursor, aider, goose, opencode
    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .copilot: return "GitHub Copilot"
        case .cursor: return "Cursor Agent"
        case .aider: return "Aider"
        case .goose: return "Goose"
        case .opencode: return "OpenCode"
        }
    }
}

/// CPU is an observable signal, not proof of what an agent is doing.
public enum AgentActivityState: String, Sendable { case consumingCPU = "Using CPU", quiet = "Quiet" }

public struct AgentSession: Identifiable, Sendable {
    public let id: String
    public let provider: AgentProvider
    public let pid: Int32
    public let projectPath: String?
    public let processIDs: [Int32]
    public let residentBytes: UInt64
    public let cpuPercent: Double
    public let state: AgentActivityState
    public let startedAt: Date
    public var projectName: String { projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown project" }
}

public enum AgentService {
    private static let argumentCache = AgentArgumentCache()
    public static func uniqueProcesses(sessions: [AgentSession], processes: [ProcessRecord]) -> [ProcessRecord] {
        let pids = Set(sessions.flatMap(\.processIDs))
        var seen = Set<Int32>()
        return processes.filter { pids.contains($0.pid) && seen.insert($0.pid).inserted }
    }
    public static func provider(name: String, executablePath: String) -> AgentProvider? {
        // Desktop application processes are not individual coding sessions.
        guard !executablePath.contains(".app/Contents/MacOS/") else { return nil }
        let executable = URL(fileURLWithPath: executablePath).lastPathComponent.lowercased()
        for candidate in [name.lowercased(), executable] {
            switch candidate {
            case "claude": return .claude
            case "codex": return .codex
            case "gemini": return .gemini
            case "copilot": return .copilot
            case "cursor-agent": return .cursor
            case "aider": return .aider
            case "goose": return .goose
            case "opencode": return .opencode
            default: continue
            }
        }
        return nil
    }

    public static func provider(arguments: [String]) -> AgentProvider? {
        guard arguments.count > 1 else { return nil }
        let executable = URL(fileURLWithPath: arguments[0]).lastPathComponent.lowercased()
        guard isInterpreter(executable) else { return nil }
        var index = 1
        while index < min(arguments.count, 12) {
            let argument = arguments[index]
            if ["-e", "--eval", "-c", "-p", "--print"].contains(argument) { return nil }
            if argument == "-m" {
                guard executable.hasPrefix("python"), index + 1 < arguments.count else { return nil }
                return ["aider", "aider.main"].contains(arguments[index + 1]) ? .aider : nil
            }
            if ["-r", "--require", "--import", "--loader"].contains(argument) { index += 2; continue }
            if argument.hasPrefix("-") { index += 1; continue }
            let components = URL(fileURLWithPath: argument).pathComponents
            func package(_ scope: String, _ name: String) -> Bool {
                zip(components, components.dropFirst()).contains { $0 == scope && $1 == name }
            }
            if package("@anthropic-ai", "claude-code") { return .claude }
            if package("@google", "gemini-cli") { return .gemini }
            if package("@github", "copilot") { return .copilot }
            if package("@openai", "codex") { return .codex }
            if package("@cursor", "agent") { return .cursor }
            let script = components.last?.lowercased() ?? ""
            switch script {
            case "claude", "claude.js": return .claude
            case "gemini", "gemini.js": return .gemini
            case "codex", "codex.js": return .codex
            case "copilot", "copilot.js": return .copilot
            case "cursor-agent": return .cursor
            case "aider": return .aider
            case "opencode": return .opencode
            default: return nil
            }
        }
        return nil
    }

    static func isInterpreter(_ name: String) -> Bool {
        ["node", "nodejs", "bun", "python", "python3"].contains(name) || name.hasPrefix("python3.")
    }

    public static func sessions(from processes: [ProcessRecord]) -> [AgentSession] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let validChildren = processes.filter { child in
            guard let parent = byPID[child.parentPID] else { return false }
            return parent.startTime <= child.startTime && parent.userID == child.userID
        }
        let children = Dictionary(grouping: validChildren, by: \.parentPID)
        let detected = Dictionary(processes.compactMap { process -> (Int32, AgentProvider)? in
            if let direct = provider(name: process.name, executablePath: process.executablePath) { return (process.pid, direct) }
            let executable = URL(fileURLWithPath: process.executablePath).lastPathComponent.lowercased()
            guard isInterpreter(executable) || isInterpreter(process.name.lowercased()), process.userID == getuid() else { return nil }
            return argumentCache.provider(for: process).map { (process.pid, $0) }
        }, uniquingKeysWith: { first, _ in first })
        return processes.compactMap { root -> AgentSession? in
            guard let provider = detected[root.pid] else { return nil }
            // Launch wrappers can share the binary name with their child.
            var ancestor = root.parentPID
            var child = root
            var ancestors = Set<Int32>()
            while ancestors.insert(ancestor).inserted, let parent = byPID[ancestor] {
                guard parent.startTime <= child.startTime, parent.userID == child.userID else { break }
                if detected[parent.pid] == provider { return nil }
                ancestor = parent.parentPID
                child = parent
            }
            var queue = [root.pid]
            var visited = Set<Int32>()
            var records: [ProcessRecord] = []
            while let pid = queue.popLast() {
                guard visited.insert(pid).inserted, let record = byPID[pid] else { continue }
                records.append(record)
                queue.append(contentsOf: (children[pid] ?? []).map(\.pid))
            }
            let cpu = records.reduce(0) { $0 + max(0, $1.cpuPercent) }
            return AgentSession(id: "\(root.pid)-\(root.startTime.timeIntervalSince1970)", provider: provider,
                pid: root.pid, projectPath: root.workingDirectory, processIDs: records.map(\.pid).sorted(),
                residentBytes: records.reduce(UInt64(0)) { $0 &+ $1.residentBytes }, cpuPercent: cpu,
                state: cpu >= 1 ? .consumingCPU : .quiet, startedAt: root.startTime)
        }.sorted { $0.startedAt < $1.startedAt }
    }
}

private final class AgentArgumentCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Int32: (start: Date, checked: Date, provider: AgentProvider?)] = [:]
    func provider(for process: ProcessRecord) -> AgentProvider? {
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[process.pid], entry.start == process.startTime, Date().timeIntervalSince(entry.checked) < 30 { return entry.provider }
        let result = AgentService.provider(arguments: Self.arguments(pid: process.pid))
        if entries.count > 4096 { entries.removeAll(keepingCapacity: true) }
        entries[process.pid] = (process.startTime, Date(), result)
        return result
    }

    private static func arguments(pid: Int32) -> [String] {
        // Fixed cap; only argc arguments are decoded. The environment is never parsed,
        // retained, logged, or returned, and the temporary kernel buffer is wiped.
        var bytes = [UInt8](repeating: 0, count: 65_536)
        defer { bytes.withUnsafeMutableBytes { buffer in if let base = buffer.baseAddress { memset(base, 0, buffer.count) } } }
        var size = bytes.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let result = bytes.withUnsafeMutableBytes { buffer in sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &size, nil, 0) }
        guard result == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 4096 else { return [] }
        var cursor = MemoryLayout<Int32>.size
        while cursor < size && bytes[cursor] != 0 { cursor += 1 }
        while cursor < size && bytes[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        for _ in 0..<min(Int(argc), 12) {
            let start = cursor
            while cursor < size && bytes[cursor] != 0 { cursor += 1 }
            guard cursor < size else { break }
            arguments.append(String(decoding: bytes[start..<cursor], as: UTF8.self))
            cursor += 1
        }
        return arguments
    }
}
