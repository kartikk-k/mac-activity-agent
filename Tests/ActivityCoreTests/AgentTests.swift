import XCTest
@testable import ActivityCore

final class AgentTests: XCTestCase {
    func testCrossProviderSessionSummaryCountsEachProcessOnce() {
        let now = Date()
        let processes = [
            ProcessRecord(pid: 10, name: "codex", residentBytes: 100, cpuPercent: 1, startTime: now),
            ProcessRecord(pid: 11, parentPID: 10, name: "claude", residentBytes: 200, cpuPercent: 2, startTime: now),
            ProcessRecord(pid: 12, parentPID: 11, name: "worker", residentBytes: 300, cpuPercent: 3, startTime: now)
        ]
        let sessions = AgentService.sessions(from: processes)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.residentBytes }, 1100)
        let summaryProcesses = AgentService.uniqueProcesses(sessions: sessions, processes: processes)
        XCTAssertEqual(summaryProcesses.reduce(0) { $0 + $1.residentBytes }, 600)
        XCTAssertEqual(summaryProcesses.reduce(0) { $0 + $1.cpuPercent }, 6)
    }

    func testCachedListenerRejectsReusedPIDAndUnknownIdentity() throws {
        let now = Date()
        let original = ProcessRecord(pid: 42, name: "node", executablePath: "/opt/bin/node", startTime: now)
        let listener = try XCTUnwrap(ProjectService.parse("p42\ncnode\nn*:9080\n", processes: [original]).first)
        XCTAssertTrue(listener.matches(original))
        // Same executable, same PID, different process birth: must not enable Stop.
        let reused = ProcessRecord(pid: 42, name: "node", executablePath: "/opt/bin/node", startTime: now.addingTimeInterval(1))
        XCTAssertFalse(listener.matches(reused))
        let unknown = try XCTUnwrap(ProjectService.parse("p42\ncnode\nn*:9080\n", processes: []).first)
        XCTAssertFalse(unknown.matches(original))
        let execChanged = ProcessRecord(pid: 42, name: "other", executablePath: "/opt/bin/other", startTime: now)
        XCTAssertFalse(listener.matches(execChanged))
    }

    func testRecycledAncestorDoesNotHideIndependentAgent() {
        let now = Date()
        let sessions = AgentService.sessions(from: [
            ProcessRecord(pid: 20, name: "codex", startTime: now, userID: 501),
            ProcessRecord(pid: 21, parentPID: 20, name: "codex", startTime: now.addingTimeInterval(-10), userID: 501)
        ])
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.flatMap(\.processIDs)), [20, 21])
        XCTAssertTrue(sessions.allSatisfy { $0.processIDs.count == 1 })
    }

    func testNonAgentProcessesDoNotProduceSession() {
        XCTAssertTrue(AgentService.sessions(from: [
            ProcessRecord(pid: 900001, name: "zsh"),
            ProcessRecord(pid: 900002, parentPID: 900001, name: "worker")
        ]).isEmpty)
    }

    func testAgentDoesNotAdoptRecycledParentPIDOrDifferentUser() {
        let now = Date()
        let records = [
            ProcessRecord(pid: 10, name: "codex", residentBytes: 100, startTime: now, userID: 501),
            ProcessRecord(pid: 11, parentPID: 10, name: "node", residentBytes: 200, startTime: now.addingTimeInterval(-10), userID: 501),
            ProcessRecord(pid: 12, parentPID: 10, name: "node", residentBytes: 300, startTime: now.addingTimeInterval(10), userID: 502),
            ProcessRecord(pid: 13, parentPID: 10, name: "node", residentBytes: 400, startTime: now.addingTimeInterval(10), userID: 501)
        ]
        let sessions = AgentService.sessions(from: records)
        XCTAssertEqual(sessions.first?.processIDs, [10, 13])
        XCTAssertEqual(sessions.first?.residentBytes, 500)
    }

    func testInterpreterAgentMatchingStopsBeforePromptArguments() {
        XCTAssertEqual(AgentService.provider(arguments: ["node", "--no-warnings", "/opt/node_modules/@google/gemini-cli/dist/index.js"]), .gemini)
        XCTAssertEqual(AgentService.provider(arguments: ["node", "/opt/node_modules/@anthropic-ai/claude-code/cli.js"]), .claude)
        XCTAssertEqual(AgentService.provider(arguments: ["python3.13", "-m", "aider"]), .aider)
        XCTAssertNil(AgentService.provider(arguments: ["node", "/project/server.js", "/fake/@google/gemini-cli/index.js"]))
        XCTAssertNil(AgentService.provider(arguments: ["node", "-e", "/fake/@google/gemini-cli/index.js"]))
        XCTAssertNil(AgentService.provider(arguments: ["bash", "/opt/node_modules/@google/gemini-cli/index.js"]))
    }

    func testClaudeUsageRequiresAssistantMessageAndCountsCacheTokens() {
        let result = AgentUsageService.parseClaude(#"{"type":"assistant","timestamp":"2026-10-15T10:00:00Z","message":{"id":"msg_1","usage":{"input_tokens":100,"output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":40}}}"#)
        XCTAssertEqual(result.first?.tokens, 190)
        XCTAssertEqual(result.first?.messageID, "msg_1")
        XCTAssertTrue(AgentUsageService.parseClaude(#"{"type":"user","message":{"usage":{"input_tokens":999}}}"#).isEmpty)
    }

    func testAgentDescendantsDoNotIncludeSiblingTerminalJobs() {
        let records = [
            ProcessRecord(pid: 100, name: "zsh"),
            ProcessRecord(pid: 101, parentPID: 100, name: "codex", residentBytes: 100, workingDirectory: "/projects/app"),
            ProcessRecord(pid: 102, parentPID: 101, name: "node", residentBytes: 200, cpuPercent: 2),
            ProcessRecord(pid: 103, parentPID: 100, name: "node", residentBytes: 500)
        ]
        let sessions = AgentService.sessions(from: records)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].processIDs, [101, 102])
        XCTAssertEqual(sessions[0].residentBytes, 300)
        XCTAssertEqual(sessions[0].state, .consumingCPU)
        XCTAssertEqual(sessions[0].projectName, "app")
    }

    func testDesktopAppsAndSubstringMatchesAreNotSessions() {
        XCTAssertNil(AgentService.provider(name: "Codex", executablePath: "/Applications/Codex.app/Contents/MacOS/Codex"))
        XCTAssertNil(AgentService.provider(name: "my-codex-script", executablePath: "/tmp/my-codex-script"))
        XCTAssertEqual(AgentService.provider(name: "codex", executablePath: "/opt/bin/codex"), .codex)
        XCTAssertEqual(AgentService.provider(name: "codex", executablePath: "/Applications/Codex.app/Contents/Resources/codex"), .codex)
    }

    func testWrapperDeduplicationAndCycleSafety() {
        let records = [ProcessRecord(pid: 1, parentPID: 3, name: "codex"),
                       ProcessRecord(pid: 2, parentPID: 1, name: "codex"),
                       ProcessRecord(pid: 3, parentPID: 2, name: "node")]
        XCTAssertTrue(AgentService.sessions(from: records).isEmpty)
    }

    func testListenerIPv6AndDuplicateParsing() {
        let records = [ProcessRecord(pid: 42, name: "node", workingDirectory: "/src/project")]
        let result = ProjectService.parse("p42\ncnode\nn*:3000\nn*:3000\nn[::1]:8080\nninvalid\n", processes: records)
        XCTAssertEqual(result.map(\.port), [3000, 8080])
        XCTAssertEqual(result.first?.projectPath, "/src/project")
    }

    func testDockerStatsParsing() {
        let result = DockerService.parse(#"{"ID":"abc","Name":"db","CPUPerc":"1.23%","MemUsage":"12MiB / 8GiB","NetIO":"1kB / 2kB","BlockIO":"0B / 0B"}"#)
        XCTAssertEqual(result.first?.name, "db")
        XCTAssertEqual(result.first?.cpuPercent, 1.23)
        XCTAssertTrue(DockerService.parse("not JSON").isEmpty)
    }

    func testUsageUsesOnlyTimestampedTokenEvents() {
        let result = AgentUsageService.parse(#"{"type":"event_msg","timestamp":"2026-10-15T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1234}},"rate_limits":{"primary":{"used_percent":25,"window_minutes":300,"resets_at":1800000000}}}}"#)
        XCTAssertEqual(result?.sessionTokens, 1234)
        XCTAssertEqual(result?.primary?.usedPercent, 25)
        XCTAssertEqual(result?.primary?.windowMinutes, 300)
        XCTAssertNil(result?.secondary)
        XCTAssertNil(AgentUsageService.parse(#"{"type":"message","payload":{"total_tokens":999}}"#))
    }
}
