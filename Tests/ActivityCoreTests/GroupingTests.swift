import XCTest
import Darwin
@testable import ActivityCore

final class GroupingTests: XCTestCase {
    private func process(_ pid: Int32, parent: Int32 = 1, path: String = "", bytes: UInt64 = 100, start: TimeInterval = 100, uid: UInt32 = 501) -> ProcessRecord {
        ProcessRecord(pid: pid, parentPID: parent, name: "p\(pid)", executablePath: path, residentBytes: bytes, startTime: Date(timeIntervalSince1970: start), userID: uid)
    }
    func testNestedAndReparentedHelpersUseOutermostBundle() {
        let main = process(10, path: "/Applications/Browser.app/Contents/MacOS/Browser")
        let helper = process(11, path: "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper")
        let groups = ProcessGrouper.group([main, helper], applications: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "Browser")
        XCTAssertEqual(groups.first?.memoryBytes, 200)
    }
    func testTerminalDescendantsAndExplicitBrowserOwnership() {
        let terminal = process(10, path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
        let shell = process(11, parent: 10, path: "/bin/zsh")
        let node = process(12, parent: 11, path: "/opt/homebrew/bin/node")
        let browser = process(13, parent: 11, path: "/Applications/Browser.app/Contents/MacOS/Browser")
        let daemon = process(14, path: "/usr/libexec/something")
        let groups = ProcessGrouper.group([node, daemon, shell, browser, terminal], applications: [])
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(Set(groups.first { $0.name == "Terminal" }!.processes.map(\.pid)), [10, 11, 12])
        XCTAssertEqual(groups.first { $0.name == "Browser" }?.processes.count, 1)
    }
    func testNoFalseAncestryThroughPIDReuseOrDifferentUser() {
        let app = process(10, path: "/Applications/App.app/Contents/MacOS/App", start: 200)
        let reusedChild = process(11, parent: 10, start: 100)
        let rootChild = process(12, parent: 10, start: 300, uid: 0)
        XCTAssertEqual(ProcessGrouper.group([app, reusedChild, rootChild], applications: []).count, 3)
    }
    func testUnknownProcessesStaySeparateAndCycleTerminates() {
        XCTAssertEqual(ProcessGrouper.group([process(10, parent: 11), process(11, parent: 10)], applications: []).count, 2)
    }
    func testWorkspaceExecutableURLDoesNotCreateFakeApplication() {
        let node = process(10, path: "/usr/local/bin/node")
        let secondNode = process(11, path: "/usr/local/bin/node")
        let running = [RunningApplication(pid: 10, name: "next-server", bundlePath: "/usr/local/bin/node")]
        let groups = ProcessGrouper.group([node, secondNode], applications: running)
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.bundlePath == nil })
        let terminal = process(12, path: "/Applications/Terminal.app/Contents/MacOS/Terminal")
        let child = process(13, parent: 12, path: "/usr/local/bin/node")
        let childMetadata = [RunningApplication(pid: 13, name: "node", bundlePath: "/usr/local/bin/node")]
        let attached = ProcessGrouper.group([terminal, child], applications: childMetadata)
        XCTAssertEqual(attached.count, 1)
        XCTAssertEqual(attached.first?.name, "Terminal")
    }
    func testNamedCommandGroupsOnlyItsSameProjectDescendants() {
        var server = process(10, path: "/usr/local/bin/node")
        var child = process(11, parent: 10, path: "/usr/local/bin/node")
        var other = process(12, path: "/usr/local/bin/node")
        server.workingDirectory = "/work/project"
        child.workingDirectory = "/work/project"
        other.workingDirectory = "/work/project"
        let running = [RunningApplication(pid: 10, name: "next-server", bundlePath: "/usr/local/bin/node")]
        let groups = ProcessGrouper.group([server, child, other], applications: running)
        XCTAssertEqual(groups.count, 2)
        let named = groups.first { $0.name == "next-server" }
        XCTAssertEqual(named?.processes.count, 2)
        XCTAssertNil(named?.bundlePath)
        XCTAssertEqual(Set(named?.processes.map(\.pid) ?? []), [10, 11])
    }
    func testCommandGroupsRuntimeAncestorsWithDescriptiveDescendantTitle() {
        var launcher = process(10, path: "/usr/local/bin/node")
        var server = process(11, parent: 10, path: "/usr/local/bin/node")
        var child = process(12, parent: 11, path: "/usr/local/bin/node")
        launcher.workingDirectory = "/work/project"
        server.workingDirectory = "/work/project"
        child.workingDirectory = "/work/project"
        let running = [RunningApplication(pid: 10, name: "npm run dev", bundlePath: "/usr/local/bin/node"), RunningApplication(pid: 11, name: "next-server", bundlePath: "/usr/local/bin/node")]
        let groups = ProcessGrouper.group([launcher, server, child], applications: running)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "next-server")
        XCTAssertEqual(Set(groups.first?.processes.map(\.pid) ?? []), [10, 11, 12])
        XCTAssertTrue(groups.allSatisfy { $0.isCommandGroup && !$0.isApplication })
    }
    func testRuntimeGroupingStopsAtShellAndKeepsAppAncestry() {
        var shell = process(10, path: "/bin/zsh")
        var node = process(11, parent: 10, path: "/usr/local/bin/node")
        var server = process(12, parent: 11, path: "/usr/local/bin/node")
        shell.workingDirectory = "/work/project"
        node.workingDirectory = "/work/project"
        server.workingDirectory = "/work/project"
        let running = [RunningApplication(pid: 12, name: "next-server", bundlePath: "/usr/local/bin/node")]
        let groups = ProcessGrouper.group([shell, node, server], applications: running)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first { $0.isCommandGroup }?.processes.count, 2)
        shell.parentPID = 13
        let terminal = process(13, path: "/Applications/Terminal.app/Contents/MacOS/Terminal")
        let appGroups = ProcessGrouper.group([terminal, shell, node, server], applications: running)
        XCTAssertEqual(appGroups.count, 1)
        XCTAssertEqual(appGroups.first?.name, "Terminal")
        XCTAssertTrue(appGroups.first?.isApplication ?? false)
    }
    func testCommandRuntimeAncestryRespectsDirectoryIdentityAndUserBoundaries() {
        for boundary in ["directory", "birth", "user"] {
            var launcher = process(10, path: "/usr/local/bin/node", start: boundary == "birth" ? 300 : 100, uid: boundary == "user" ? 0 : 501)
            var server = process(11, parent: 10, path: "/usr/local/bin/node", start: 200)
            launcher.workingDirectory = boundary == "directory" ? "/work/other" : "/work/project"
            server.workingDirectory = "/work/project"
            let running = [RunningApplication(pid: 11, name: "next-server", bundlePath: "/usr/local/bin/node")]
            let groups = ProcessGrouper.group([launcher, server], applications: running)
            XCTAssertEqual(groups.count, 2, boundary)
            XCTAssertEqual(groups.first { $0.isCommandGroup }?.processes.map(\.pid), [11], boundary)
        }
    }
    func testCPUResetOnPIDReuseAndCounterReset() {
        XCTAssertEqual(ProcessSampler.cpuPercentage(previousCPU: 100, currentCPU: 500_000_100, elapsed: 2, sameProcess: true), 25)
        XCTAssertEqual(ProcessSampler.cpuPercentage(previousCPU: 100, currentCPU: 500_000_100, elapsed: 2, sameProcess: false), 0)
        XCTAssertEqual(ProcessSampler.cpuPercentage(previousCPU: 500, currentCPU: 100, elapsed: 2, sameProcess: true), 0)
    }
    func testSamplerReadsActualStoppedAndResumedChildState() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()
        defer {
            kill(child.processIdentifier, SIGCONT)
            child.terminate()
            child.waitUntilExit()
        }
        let sampler = ProcessSampler()
        XCTAssertEqual(sampler.sample().first { $0.pid == child.processIdentifier }?.isStopped, false)
        XCTAssertEqual(kill(child.processIdentifier, SIGSTOP), 0)
        var stopped = false
        for _ in 0..<20 {
            if sampler.sample().first(where: { $0.pid == child.processIdentifier })?.isStopped == true { stopped = true; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(stopped)
        XCTAssertEqual(kill(child.processIdentifier, SIGCONT), 0)
        var resumed = false
        for _ in 0..<20 {
            if sampler.sample().first(where: { $0.pid == child.processIdentifier })?.isStopped == false { resumed = true; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(resumed)
    }
    func testLiveCPUPercentMatchesGetrusageTimebase() {
        func ownCPUSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let sampler = ProcessSampler()
        _ = sampler.sample()
        let cpuStart = ownCPUSeconds()
        let start = ProcessInfo.processInfo.systemUptime
        // Deliberate CPU work in the test process only. A 150ms CPU window is long
        // enough to catch confusing Mach ticks with nanoseconds on Apple Silicon.
        while ownCPUSeconds() - cpuStart < 0.15 { _ = ProcessInfo.processInfo.systemUptime }
        let record = sampler.sample().first { $0.pid == getpid() }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let expected = (ownCPUSeconds() - cpuStart) / elapsed * 100
        XCTAssertNotNil(record)
        XCTAssertGreaterThan(record?.cpuPercent ?? 0, expected * 0.5)
        XCTAssertLessThan(record?.cpuPercent ?? .infinity, expected * 2)
    }
    func testLiveSamplerIncludesSelfAndStableIdentity() {
        let sampler = ProcessSampler()
        let first = sampler.sample().first { $0.pid == ProcessInfo.processInfo.processIdentifier }
        XCTAssertNotNil(first)
        XCTAssertGreaterThan(first?.residentBytes ?? 0, 0)
        XCTAssertFalse(first?.executablePath.isEmpty ?? true)
        XCTAssertEqual(first?.cpuPercent, 0)
        let second = sampler.sample().first { $0.pid == ProcessInfo.processInfo.processIdentifier }
        XCTAssertEqual(first?.startTime, second?.startTime)
    }
}
