import XCTest
@testable import ActivityCore

final class HistoryTests: XCTestCase {
    private func snapshot(_ date: Date) -> SystemSnapshot {
        SystemSnapshot(timestamp: date, cpuPercent: 12, memoryTotal: 1000, memoryUsed: 500, memoryWired: 100, memoryCompressed: 50, memoryCached: 100, swapUsed: 0, networkReceivedBytes: 0, networkSentBytes: 0, diskReadBytes: 0, diskWriteBytes: 0, batteryPercent: nil, isCharging: false, thermalState: "Nominal", uptime: 1)
    }
    func testSamplingRetentionAndPersistence() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(directory: folder)
        let now = Date()
        let app = HistoryAppMetric(id: "test", name: "Test", cpuPercent: 30, memoryBytes: 100)
        store.record(system: snapshot(now.addingTimeInterval(-31 * 86400)), apps: [app])
        store.record(system: snapshot(now.addingTimeInterval(-2 * 86400)), apps: [app])
        store.record(system: snapshot(now.addingTimeInterval(-2 * 86400 + 60)), apps: [app])
        store.record(system: snapshot(now.addingTimeInterval(-120)), apps: [app])
        store.record(system: snapshot(now.addingTimeInterval(-110)), apps: [app])
        store.record(system: snapshot(now), apps: [app])
        store.flush()
        let reloaded = HistoryStore(directory: folder)
        // Two old samples may cross an hour boundary; no expired data survives.
        XCTAssertTrue((3...4).contains(reloaded.samples().count))
        XCTAssertTrue(reloaded.samples().allSatisfy { $0.timestamp >= now.addingTimeInterval(-30 * 86400) })
        XCTAssertEqual(reloaded.samples(since: now.addingTimeInterval(-60)).count, 1)
        XCTAssertEqual(reloaded.samples().last?.apps.first?.id, "test")
        reloaded.clear()
        XCTAssertEqual(HistoryStore(directory: folder).samples().count, 0)
    }
    func testCPUAlertRequiresSustainedLoadAndResetsAfterRecovery() {
        var config = AlertConfiguration(); config.cpuDuration = 60; config.cooldown = 300
        let evaluator = AlertEvaluator(configuration: config), now = Date()
        func app(_ cpu: Double) -> HistoryAppMetric { HistoryAppMetric(id: "a", name: "App", cpuPercent: cpu, memoryBytes: 100) }
        XCTAssertTrue(evaluator.evaluate(apps: [app(150)], at: now).isEmpty)
        XCTAssertTrue(evaluator.evaluate(apps: [app(150)], at: now.addingTimeInterval(59)).isEmpty)
        XCTAssertEqual(evaluator.evaluate(apps: [app(150)], at: now.addingTimeInterval(60)).first?.kind, .sustainedCPU)
        XCTAssertTrue(evaluator.evaluate(apps: [app(150)], at: now.addingTimeInterval(120)).isEmpty)
        XCTAssertTrue(evaluator.evaluate(apps: [app(0)], at: now.addingTimeInterval(360)).isEmpty)
        XCTAssertTrue(evaluator.evaluate(apps: [app(150)], at: now.addingTimeInterval(361)).isEmpty)
        XCTAssertEqual(evaluator.evaluate(apps: [app(150)], at: now.addingTimeInterval(421)).first?.kind, .sustainedCPU)
    }
    func testDiskUsesCounterDeltasAndMemoryRequiresFullWindow() {
        var config = AlertConfiguration(); config.diskBytesPerSecond = 100; config.diskDuration = 10; config.memoryGrowthBytes = 100; config.memoryWindow = 30
        let evaluator = AlertEvaluator(configuration: config), now = Date()
        func app(_ disk: UInt64, _ memory: UInt64) -> HistoryAppMetric { HistoryAppMetric(id: "a", name: "App", cpuPercent: 0, memoryBytes: memory, diskReadBytes: disk) }
        XCTAssertTrue(evaluator.evaluate(apps: [app(1_000_000, 100)], at: now).isEmpty)
        XCTAssertTrue(evaluator.evaluate(apps: [app(1_002_000, 300)], at: now.addingTimeInterval(10)).isEmpty)
        XCTAssertEqual(evaluator.evaluate(apps: [app(1_004_000, 300)], at: now.addingTimeInterval(20)).map(\.kind), [.diskActivity])
        XCTAssertEqual(evaluator.evaluate(apps: [app(1_004_000, 300)], at: now.addingTimeInterval(30)).map(\.kind), [.memoryGrowth])
    }
    func testNetworkAlertIsSystemWideAndGapResetsSustainedWindow() {
        var config = AlertConfiguration(); config.networkBytesPerSecond = 100; config.networkDuration = 30
        let evaluator = AlertEvaluator(configuration: config), now = Date()
        func network(_ offset: TimeInterval) -> SystemSnapshot {
            var value = snapshot(now.addingTimeInterval(offset)); value.networkReceivedBytes = 101; return value
        }
        XCTAssertTrue(evaluator.evaluate(system: network(0)).isEmpty)
        XCTAssertTrue(evaluator.evaluate(system: network(20)).isEmpty)
        // Pausing/sleeping is not evidence of sustained activity.
        XCTAssertTrue(evaluator.evaluate(system: network(100)).isEmpty)
        let alerts = evaluator.evaluate(system: network(130))
        XCTAssertEqual(alerts.first?.kind, .networkActivity)
        XCTAssertEqual(alerts.first?.appID, "system")
        XCTAssertTrue(evaluator.evaluate(system: network(160)).isEmpty)
    }

}
