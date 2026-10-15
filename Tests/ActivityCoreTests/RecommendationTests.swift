import XCTest
@testable import ActivityCore

final class RecommendationTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func group(cpu: Double = 0, disk: UInt64 = 10, pid: Int32 = 42, age: TimeInterval = 7200) -> AppGroup {
        AppGroup(id: "app", name: "Editor", bundlePath: "/Applications/Editor.app", processes: [
            ProcessRecord(pid: pid, name: "Editor", cpuPercent: cpu, diskReadBytes: disk, startTime: base.addingTimeInterval(-age))
        ])
    }
    private func service() -> RecommendationService {
        RecommendationService(minimumIdleDuration: 120, minimumRunningDuration: 3600, maximumObservationGap: 90)
    }
    func testRequiresFreshContinuousObservations() {
        let service = service()
        XCTAssertTrue(service.evaluate(groups: [group()], frontmostBundlePath: nil, at: base).isEmpty)
        XCTAssertTrue(service.evaluate(groups: [group()], frontmostBundlePath: nil, at: base.addingTimeInterval(60)).isEmpty)
        let result = service.evaluate(groups: [group()], frontmostBundlePath: nil, at: base.addingTimeInterval(120))
        XCTAssertEqual(result.first?.groupID, "app")
        XCTAssertEqual(result.first?.idleDuration, 120)
    }
    func testLongObservationGapDoesNotCountAsObservedIdle() {
        let service = service()
        _ = service.evaluate(groups: [group()], frontmostBundlePath: nil, at: base)
        XCTAssertTrue(service.evaluate(groups: [group()], frontmostBundlePath: nil, at: base.addingTimeInterval(600)).isEmpty)
    }
    func testDiskAndCPUActivityRestartObservation() {
        for changed in [group(cpu: 2), group(disk: 50), group(pid: 43)] {
            let service = service()
            _ = service.evaluate(groups: [group()], frontmostBundlePath: nil, at: base)
            _ = service.evaluate(groups: [changed], frontmostBundlePath: nil, at: base.addingTimeInterval(60))
            XCTAssertTrue(service.evaluate(groups: [group()], frontmostBundlePath: nil, at: base.addingTimeInterval(120)).isEmpty)
        }
    }
    func testProtectedAndYoungAppsNeverSuggested() {
        for protection in 0...2 {
            let service = service()
            for seconds in stride(from: 0, through: 180, by: 60) {
                let result = service.evaluate(groups: [group(age: protection == 2 ? 60 : 7200)],
                    frontmostBundlePath: protection == 0 ? "/Applications/Editor.app" : nil,
                    keepRunningIDs: protection == 1 ? ["app"] : [], at: base.addingTimeInterval(Double(seconds)))
                XCTAssertTrue(result.isEmpty)
            }
        }
    }
    func testDisappearingAppResetsObservation() {
        let service = service()
        _ = service.evaluate(groups: [group()], frontmostBundlePath: nil, at: base)
        _ = service.evaluate(groups: [], frontmostBundlePath: nil, at: base.addingTimeInterval(60))
        XCTAssertTrue(service.evaluate(groups: [group()], frontmostBundlePath: nil, at: base.addingTimeInterval(120)).isEmpty)
    }
    func testPortsRetainMultipleListenersPerPIDAndDeduplicateIPv4IPv6() {
        let parsed = ProjectService.parse("p42\ncnext-server\nn*:6000\nn[::1]:6000\nn*:9080\n", processes: [])
        XCTAssertEqual(ProjectService.portsByPID(parsed)[42], [6000, 9080])
    }
}
