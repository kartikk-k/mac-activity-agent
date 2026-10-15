#!/usr/bin/env swift
import Foundation
import AppKit
import Darwin

// Read-only measurement of another process. The observer's CPU is excluded.
// Usage: swift scripts/measure-app.swift PID --seconds 45 --label visible
// No app is activated, hidden, paused, or otherwise modified.
struct MeasurementError: Error, CustomStringConvertible {
    let description: String
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
let arguments = CommandLine.arguments
func option(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}
guard arguments.count > 1, let pid = Int32(arguments[1]), pid > 1 else {
    fail("Usage: swift scripts/measure-app.swift PID [--seconds 45] [--label sample]")
}
let duration = Double(option("--seconds") ?? "45") ?? 0
guard duration.isFinite, duration > 0, duration <= 3600 else { fail("--seconds must be between 0 and 3600") }
let label = option("--label") ?? "sample"

func snapshot() throws -> rusage_info_v2 {
    var info = rusage_info_v2()
    let status = withUnsafeMutableBytes(of: &info) { bytes in
        proc_pid_rusage(pid, RUSAGE_INFO_V2, bytes.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
    }
    guard status == 0 else { throw MeasurementError(description: "Cannot read process \(pid): \(String(cString: strerror(errno)))") }
    return info
}
func cpuTicks(_ sample: rusage_info_v2) -> UInt64 {
    sample.ri_user_time + sample.ri_system_time
}

do {
    let startDate = Date()
    let initial = try snapshot()
    let started = ProcessInfo.processInfo.systemUptime
    var activeObservations = 0, hiddenObservations = 0, observations = 0
    var activationTransitions = 0
    var previousActive: Bool?
    func observe() throws {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            throw MeasurementError(description: "Target process \(pid) exited or is not a running macOS application")
        }
        let active = app.isActive
        if active { activeObservations += 1 }
        if app.isHidden { hiddenObservations += 1 }
        if let previousActive, previousActive != active { activationTransitions += 1 }
        previousActive = active
        observations += 1
    }
    while true {
        try observe()
        let remaining = duration - (ProcessInfo.processInfo.systemUptime - started)
        if remaining <= 0 { break }
        // Keep AppKit's workspace notifications current without changing focus.
        let interval = min(1, remaining)
        let nextObservation = ProcessInfo.processInfo.systemUptime + interval
        RunLoop.current.run(until: Date().addingTimeInterval(interval))
        let remainder = nextObservation - ProcessInfo.processInfo.systemUptime
        if remainder > 0 { Thread.sleep(forTimeInterval: remainder) }
    }
    let final = try snapshot()
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    guard initial.ri_proc_start_abstime == final.ri_proc_start_abstime else {
        throw MeasurementError(description: "PID was reused during the observation; measurement discarded")
    }
    guard cpuTicks(final) >= cpuTicks(initial) else {
        throw MeasurementError(description: "CPU counter reset; measurement discarded")
    }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let cpu = Double(cpuTicks(final) - cpuTicks(initial)) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    let dateFormatter = ISO8601DateFormatter()
    let result: [String: Any] = [
        "label": label, "pid": pid, "startedAt": dateFormatter.string(from: startDate),
        "cpuCounterUnit": "Mach absolute ticks converted to nanoseconds", "timebaseNumerator": timebase.numer, "timebaseDenominator": timebase.denom,
        "startCPUTicks": cpuTicks(initial), "endCPUTicks": cpuTicks(final), "cpuTickDelta": cpuTicks(final) - cpuTicks(initial),
        "wallSeconds": elapsed, "cpuSeconds": cpu, "cpuPercentOneCore": cpu / elapsed * 100,
        "startFootprintBytes": initial.ri_phys_footprint, "endFootprintBytes": final.ri_phys_footprint,
        "startResidentBytes": initial.ri_resident_size, "endResidentBytes": final.ri_resident_size,
        "activeObservationFraction": Double(activeObservations) / Double(observations),
        "hiddenObservationFraction": Double(hiddenObservations) / Double(observations),
        "activeObservations": activeObservations, "observations": observations,
        "activationTransitions": activationTransitions,
        "scope": "Target process CPU only; observer excluded. Active fraction is sampled once per second, not exact active duration. Focus is unchanged."
    ]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
} catch {
    fail(String(describing: error))
}
