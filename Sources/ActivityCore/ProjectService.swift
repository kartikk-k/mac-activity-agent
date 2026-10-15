import Foundation

public struct ProjectListener: Identifiable, Sendable {
    public let pid: Int32
    public let processName: String
    public let address: String
    public let port: Int
    public let projectPath: String?
    public let processStartTime: Date?
    public let executablePath: String?
    public var id: String { "\(pid):\(address)" }
    public func matches(_ process: ProcessRecord) -> Bool {
        guard let processStartTime, let executablePath else { return false }
        return process.pid == pid && process.startTime == processStartTime && process.executablePath == executablePath
    }
}

public actor ProjectService {
    private var lastRefresh = Date.distantPast
    private var cached: [ProjectListener] = []
    private var pendingRefresh: Task<[ProjectListener], Never>?
    public init() {}

    /// Use while app or project rows are visible. Manual refresh bypasses the 30-second
    /// cache; simultaneous requests share one bounded subprocess.
    public func listeners(processes: [ProcessRecord], forceRefresh: Bool = false) async -> [ProjectListener] {
        if let pendingRefresh { return await pendingRefresh.value }
        guard forceRefresh || Date().timeIntervalSince(lastRefresh) >= 30 else { return cached }
        let task = Task {
            let result = await LocalCommand.run("/usr/sbin/lsof", arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"], timeout: 4)
            return result.status == 0 ? Self.parse(result.output, processes: processes) : []
        }
        pendingRefresh = task
        cached = await task.value
        lastRefresh = Date()
        pendingRefresh = nil
        return cached
    }

    public static func portsByPID(_ listeners: [ProjectListener]) -> [Int32: [Int]] {
        Dictionary(grouping: listeners, by: \.pid).mapValues { Array(Set($0.map(\.port))).sorted() }
    }

    public static func parse(_ output: String, processes: [ProcessRecord]) -> [ProjectListener] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var pid: Int32?
        var name = ""
        var listeners: [ProjectListener] = []
        var seen = Set<String>()
        for line in output.split(separator: "\n") {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())
            switch prefix {
            case "p": pid = Int32(value); name = ""
            case "c": name = value
            case "n":
                guard let pid, let separator = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: separator)...]), (1...65535).contains(port),
                      seen.insert("\(pid):\(value)").inserted else { continue }
                listeners.append(ProjectListener(pid: pid, processName: byPID[pid]?.name ?? name,
                    address: value, port: port, projectPath: byPID[pid]?.workingDirectory,
                    processStartTime: byPID[pid].flatMap { $0.startTime > Date(timeIntervalSince1970: 0) ? $0.startTime : nil },
                    executablePath: byPID[pid]?.executablePath))
            default: break
            }
        }
        return listeners.sorted { $0.port == $1.port ? $0.pid < $1.pid : $0.port < $1.port }
    }
}
