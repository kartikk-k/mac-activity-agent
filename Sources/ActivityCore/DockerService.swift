import Foundation
import Darwin

public struct DockerContainer: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let cpuPercent: Double
    public let memoryUsage: String
    public let networkIO: String
    public let blockIO: String
}

public struct DockerSnapshot: Sendable {
    public let containers: [DockerContainer]
    public let unavailableReason: String?
    public let sampledAt: Date
}

public enum DockerService {
    /// Explicitly requested only: does not start Docker or poll its daemon in the background.
    public static func snapshot() async -> DockerSnapshot {
        let candidates = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return DockerSnapshot(containers: [], unavailableReason: "Docker CLI is not installed.", sampledAt: Date())
        }
        let desktopSocket = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker/run/docker.sock").path
        let socket = FileManager.default.fileExists(atPath: desktopSocket) ? desktopSocket : "/var/run/docker.sock"
        let result = await LocalCommand.run(binary, arguments: ["--host", "unix://\(socket)", "stats", "--no-stream", "--format", "{{json .}}"], timeout: 6)
        guard result.status == 0 else {
            return DockerSnapshot(containers: [], unavailableReason: result.timedOut ? "Docker did not respond within 6 seconds." : "Local Docker engine is unavailable.", sampledAt: Date())
        }
        return DockerSnapshot(containers: parse(result.output), unavailableReason: nil, sampledAt: Date())
    }

    public static func parse(_ output: String) -> [DockerContainer] {
        output.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["ID"] as? String, let name = json["Name"] as? String else { return nil }
            return DockerContainer(id: id, name: name,
                cpuPercent: Double((json["CPUPerc"] as? String ?? "0").replacingOccurrences(of: "%", with: "")) ?? 0,
                memoryUsage: json["MemUsage"] as? String ?? "Unavailable",
                networkIO: json["NetIO"] as? String ?? "Unavailable", blockIO: json["BlockIO"] as? String ?? "Unavailable")
        }
    }
}

struct LocalCommandResult: Sendable {
    let output: String
    let status: Int32
    let timedOut: Bool
}

enum LocalCommand {
    static func run(_ executable: String, arguments: [String], timeout: TimeInterval) async -> LocalCommandResult {
        await Task.detached(priority: .utility) {
            let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let output = try? FileHandle(forWritingTo: outputURL) else {
                return LocalCommandResult(output: "", status: -1, timedOut: false)
            }
            defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return LocalCommandResult(output: "", status: -1, timedOut: false) }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
            let timedOut = process.isRunning
            if timedOut { process.terminate() }
            let terminationDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < terminationDeadline { try? await Task.sleep(nanoseconds: 50_000_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            let reader = try? FileHandle(forReadingFrom: outputURL)
            defer { try? reader?.close() }
            let data = (try? reader?.read(upToCount: 1_048_576)) ?? Data()
            return LocalCommandResult(output: String(data: data, encoding: .utf8) ?? "", status: process.terminationStatus, timedOut: timedOut)
        }.value
    }
}
