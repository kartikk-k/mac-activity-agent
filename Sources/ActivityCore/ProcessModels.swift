import Foundation

public struct ProcessRecord: Identifiable, Codable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    public var name: String
    public var executablePath: String
    public var bundlePath: String?
    public var residentBytes: UInt64
    public var cpuPercent: Double
    public var diskReadBytes: UInt64
    public var diskWriteBytes: UInt64
    public var startTime: Date
    public var workingDirectory: String?
    public var isStopped: Bool
    public var userID: UInt32
    public var id: Int32 { pid }
    public init(pid: Int32, parentPID: Int32 = 1, name: String, executablePath: String = "", bundlePath: String? = nil, residentBytes: UInt64 = 0, cpuPercent: Double = 0, diskReadBytes: UInt64 = 0, diskWriteBytes: UInt64 = 0, startTime: Date = .distantPast, workingDirectory: String? = nil, userID: UInt32 = 0, isStopped: Bool = false) {
        self.pid = pid; self.parentPID = parentPID; self.name = name; self.executablePath = executablePath; self.bundlePath = bundlePath
        self.residentBytes = residentBytes; self.cpuPercent = cpuPercent; self.diskReadBytes = diskReadBytes; self.diskWriteBytes = diskWriteBytes
        self.startTime = startTime; self.workingDirectory = workingDirectory; self.userID = userID; self.isStopped = isStopped
    }
}
public struct AppGroup: Identifiable, Codable, Sendable {
    public var id: String
    public var name: String
    public var bundlePath: String?
    public var processes: [ProcessRecord]
    public var isApplication: Bool { bundlePath != nil }
    public var isCommandGroup: Bool { id.hasPrefix("command:") }
    public var memoryBytes: UInt64 { processes.reduce(0) { $0 &+ $1.residentBytes } }
    public var cpuPercent: Double { processes.reduce(0) { $0 + $1.cpuPercent } }
    public var diskReadBytes: UInt64 { processes.reduce(0) { $0 &+ $1.diskReadBytes } }
    public var diskWriteBytes: UInt64 { processes.reduce(0) { $0 &+ $1.diskWriteBytes } }
    public init(id: String, name: String, bundlePath: String?, processes: [ProcessRecord]) {
        self.id = id; self.name = name; self.bundlePath = bundlePath; self.processes = processes
    }
}
public struct RunningApplication: Sendable {
    public var pid: Int32
    public var name: String
    public var bundlePath: String?
    public var bundleIdentifier: String?
    public init(pid: Int32, name: String, bundlePath: String?, bundleIdentifier: String? = nil) {
        self.pid = pid; self.name = name; self.bundlePath = bundlePath; self.bundleIdentifier = bundleIdentifier
    }
}
