import Foundation
import AppKit
import Darwin
import ActivityCore

// Stdout is reserved for one JSON-RPC object per line. No background timer or
// process control capability is exposed by this read-only server.
let processSampler = ProcessSampler()
let systemSampler = SystemSampler()
let projects = ProjectService()
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.sortedKeys]
var primed = false

func applications() -> [RunningApplication] {
    NSWorkspace.shared.runningApplications.map {
        RunningApplication(pid: $0.processIdentifier, name: $0.localizedName ?? "Application", bundlePath: $0.bundleURL?.path, bundleIdentifier: $0.bundleIdentifier)
    }
}
func encode<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: encoder.encode(value))
}
func write(_ object: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}
func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}
func prime() {
    if !primed {
        _ = processSampler.sample(); _ = systemSampler.sample()
        usleep(200_000)
        primed = true
    }
}
func benchmark() {
    let arguments = CommandLine.arguments
    func option(_ flag: String, fallback: Double) -> Double {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1), let value = Double(arguments[index + 1]), value.isFinite else { return fallback }
        return value
    }
    let duration = min(300, max(1, option("--seconds", fallback: 10)))
    let interval = min(60, max(0.1, option("--interval", fallback: 3)))
    let cpuStart = cpuSeconds(), started = ProcessInfo.processInfo.systemUptime
    var samples = 0, processCount = 0, appCount = 0, conservation = true
    var sampleTimes: [Double] = []
    var stageCPU: [String: Double] = ["processSampling": 0, "workspaceMetadata": 0, "grouping": 0, "systemSampling": 0]
    repeat {
        let begin = ProcessInfo.processInfo.systemUptime
        var mark = cpuSeconds()
        let records = processSampler.sample()
        var after = cpuSeconds(); stageCPU["processSampling", default: 0] += after - mark; mark = after
        let running = applications()
        after = cpuSeconds(); stageCPU["workspaceMetadata", default: 0] += after - mark; mark = after
        let groups = ProcessGrouper.group(records, applications: running)
        after = cpuSeconds(); stageCPU["grouping", default: 0] += after - mark; mark = after
        _ = systemSampler.sample()
        after = cpuSeconds(); stageCPU["systemSampling", default: 0] += after - mark
        conservation = conservation && groups.reduce(0) { $0 + $1.processes.count } == records.count && Set(groups.flatMap(\.processes).map(\.pid)).count == records.count
        processCount = records.count; appCount = groups.filter { $0.bundlePath != nil }.count
        samples += 1
        sampleTimes.append(ProcessInfo.processInfo.systemUptime - begin)
        let remaining = duration - (ProcessInfo.processInfo.systemUptime - started)
        if remaining > 0 { usleep(useconds_t(min(remaining, interval) * 1_000_000)) }
    } while ProcessInfo.processInfo.systemUptime - started < duration
    let elapsed = ProcessInfo.processInfo.systemUptime - started, cpu = cpuSeconds() - cpuStart
    write(["mode": "benchmark", "scope": "process sampling, app metadata, grouping and system sampling; excludes UI", "durationSeconds": elapsed, "intervalSeconds": interval, "samples": samples, "stageMeanCPUMilliseconds": stageCPU.mapValues { $0 / Double(samples) * 1000 }, "processCount": processCount, "applicationCount": appCount, "groupingConservesProcesses": conservation, "cpuSeconds": cpu, "cpuPercentOneCore": cpu / elapsed * 100, "meanSampleWallMilliseconds": sampleTimes.reduce(0, +) / Double(samples) * 1000, "maxSampleWallMilliseconds": (sampleTimes.max() ?? 0) * 1000])
}

let emptySchema: [String: Any] = ["type": "object", "properties": [:], "additionalProperties": false]
let readOnly: [String: Any] = ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
let tools: [[String: Any]] = [
    ["name": "system_snapshot", "description": "Read current CPU, RAM, swap, battery, thermal state and disk/network bytes per second. CPU and rates are deltas since the previous request; the first request samples a 200 ms window. Unsupported GPU and temperature values are null.", "inputSchema": emptySchema, "annotations": readOnly],
    ["name": "list_applications", "description": "Read processes grouped by their outer application bundle and validated parent ancestry. Includes individually unowned system processes. Memory is summed process physical footprint; CPU percentages can exceed 100 for multicore processes; disk bytes are lifetime counters.", "inputSchema": ["type": "object", "properties": ["query": ["type": "string", "description": "Optional case-insensitive app name filter"]], "additionalProperties": false], "annotations": readOnly],
    ["name": "list_processes", "description": "Read live process IDs, parent IDs, executable paths, working directories where available, physical memory footprints, CPU percentages and lifetime disk counters.", "inputSchema": ["type": "object", "properties": ["pid": ["type": "integer", "minimum": 1]], "additionalProperties": false], "annotations": readOnly],
    ["name": "list_ports", "description": "Read TCP listening ports visible to the current user, with owning processes and project directories. Cached for 30 seconds. Permission restrictions may omit processes.", "inputSchema": emptySchema, "annotations": readOnly]
]

if CommandLine.arguments.contains("--benchmark") {
    benchmark()
} else {
    while let line = readLine() {
        guard let data = line.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else {
            write(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]); continue
        }
        guard let request = value as? [String: Any], request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
            write(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid request"]]); continue
        }
        guard let id = request["id"] else { continue }
        let params = request["params"] as? [String: Any] ?? [:]
        var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? "2025-03-26"
            let supported = ["2024-11-05", "2025-03-26", "2025-06-18"]
            response["result"] = ["protocolVersion": supported.contains(requested) ? requested : "2025-03-26", "capabilities": ["tools": ["listChanged": false]], "serverInfo": ["name": "activity-agent", "version": "1.0.0"], "instructions": "Read-only local Mac telemetry. No process termination or mutation tools. CPU rates measure the interval since the previous sample."]
        case "ping": response["result"] = [:] as [String: Any]
        case "tools/list": response["result"] = ["tools": tools]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            if !tools.contains(where: { $0["name"] as? String == name }) {
                response["error"] = ["code": -32602, "message": "Unknown tool: \(name)"]
            } else if (name == "list_processes" && arguments["pid"] != nil && (arguments["pid"] as? Int ?? 0) < 1)
                || (name == "list_applications" && arguments["query"] != nil && arguments["query"] as? String == nil)
                || arguments.keys.contains(where: { key in !(name == "list_processes" && key == "pid") && !(name == "list_applications" && key == "query") }) {
                response["error"] = ["code": -32602, "message": "Invalid tool arguments"]
            } else {
                do {
                    prime()
                    let result: Any
                    switch name {
                    case "system_snapshot":
                        var snapshot = try encode(systemSampler.sample()) as! [String: Any]
                        snapshot["gpuPercent"] = NSNull(); snapshot["temperatureCelsius"] = NSNull()
                        result = snapshot
                    case "list_applications":
                        var groups = ProcessGrouper.group(processSampler.sample(), applications: applications())
                        if let query = arguments["query"] as? String { groups = groups.filter { $0.name.localizedCaseInsensitiveContains(query) } }
                        result = try groups.map { group -> [String: Any] in
                            var item = try encode(group) as! [String: Any]
                            item["memoryBytes"] = group.memoryBytes; item["cpuPercent"] = group.cpuPercent
                            item["diskReadBytes"] = group.diskReadBytes; item["diskWriteBytes"] = group.diskWriteBytes
                            item["processCount"] = group.processes.count
                            return item
                        }
                    case "list_ports":
                        let listeners = await projects.listeners(processes: processSampler.sample())
                        result = listeners.map { ["pid": $0.pid, "processName": $0.processName, "address": $0.address, "port": $0.port, "projectPath": $0.projectPath as Any? ?? NSNull()] as [String: Any] }
                    default:
                        var records = processSampler.sample()
                        if let pid = arguments["pid"] as? Int { records = records.filter { Int($0.pid) == pid } }
                        result = try encode(records)
                    }
                    let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                    response["result"] = ["content": [["type": "text", "text": String(decoding: json, as: UTF8.self)]], "isError": false]
                } catch {
                    response["result"] = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
                }
            }
        default: response["error"] = ["code": -32601, "message": "Method not found"]
        }
        write(response)
    }
}
