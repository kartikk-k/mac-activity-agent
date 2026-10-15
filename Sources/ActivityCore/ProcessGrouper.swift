import Foundation

public enum ProcessGrouper {
    /// The outermost app owns nested helper apps even after launchd reparents them.
    public static func outerApplicationPath(_ path: String) -> String? {
        guard let range = path.range(of: ".app/", options: .caseInsensitive) else {
            return path.lowercased().hasSuffix(".app") ? path : nil
        }
        return String(path[..<range.lowerBound]) + String(path[range.lowerBound..<path.index(range.lowerBound, offsetBy: 4)])
    }
    public static func group(_ processes: [ProcessRecord], applications: [RunningApplication]) -> [AppGroup] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let running = Dictionary(applications.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var appByPath: [String: RunningApplication] = [:]
        for app in applications {
            guard let rawPath = app.bundlePath, let path = outerApplicationPath(rawPath) else { continue }
            // Prefer the actual outer app's localized name over helper apps,
            // without reparsing paths inside an O(n log n) sort comparator.
            if appByPath[path] == nil || rawPath == path { appByPath[path] = app }
        }
        struct Owner { var id: String; var name: String; var path: String? }
        var owners: [Int32: Owner] = [:]
        func directOwner(_ process: ProcessRecord) -> Owner? {
            if let path = outerApplicationPath(process.bundlePath ?? process.executablePath) {
                return Owner(id: "app:" + path, name: appByPath[path]?.name ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, path: path)
            }
            if let app = running[process.pid], let path = app.bundlePath, let outer = outerApplicationPath(path) {
                return Owner(id: "app:" + outer, name: appByPath[outer]?.name ?? app.name, path: outer)
            }
            return nil
        }
        // Seed explicit bundle ownership before ancestry so nested browser apps never
        // become part of whichever terminal happened to launch their main process.
        for process in processes { owners[process.pid] = directOwner(process) }
        var commandOwners: [Int32: Owner] = [:]
        var commandLabelRanks: [Int32: (depth: Int, pid: Int32)] = [:]
        let runtimeNames: Set<String> = ["node", "nodejs", "bun", "npm", "npx"]
        func isRuntime(_ process: ProcessRecord) -> Bool {
            runtimeNames.contains(URL(fileURLWithPath: process.executablePath).lastPathComponent.lowercased())
        }
        for process in processes {
            guard owners[process.pid] == nil, let app = running[process.pid],
                  let cwd = process.workingDirectory, cwd != "/", cwd != NSHomeDirectory(),
                  app.name != process.name, app.name != URL(fileURLWithPath: process.executablePath).lastPathComponent,
                  !app.name.isEmpty else { continue }
            var root = process
            var depth = 0
            var visited: Set<Int32> = [process.pid]
            while isRuntime(root), root.parentPID > 1, let parent = byPID[root.parentPID], visited.insert(parent.pid).inserted {
                guard isRuntime(parent), owners[parent.pid] == nil,
                      parent.startTime <= root.startTime, parent.userID == process.userID,
                      parent.workingDirectory == cwd else { break }
                root = parent
                depth += 1
            }
            // A framework process often sits below npm and a Node wrapper. Treat
            // that connected runtime tree as one command while retaining the
            // deeper, descriptive framework title rather than the launcher title.
            let previous = commandLabelRanks[root.pid]
            if previous == nil || depth > previous!.depth || (depth == previous!.depth && process.pid < previous!.pid) {
                commandLabelRanks[root.pid] = (depth, process.pid)
                commandOwners[root.pid] = Owner(id: "command:\(root.pid):\(root.startTime.timeIntervalSince1970)", name: app.name, path: nil)
            }
        }
        var groups: [String: AppGroup] = [:]
        for process in processes {
            var owner = owners[process.pid]
            if owner == nil {
                var current = process
                var visited: Set<Int32> = [process.pid]
                while current.parentPID > 1, let parent = byPID[current.parentPID], visited.insert(parent.pid).inserted {
                    // A parent newer than its child is a recycled PID, not ancestry.
                    guard parent.startTime <= current.startTime, parent.userID == process.userID else { break }
                    if let found = owners[parent.pid] { owner = found; break }
                    current = parent
                }
            }
            if owner == nil {
                // A runtime may publish a descriptive LaunchServices title without
                // being an app bundle (for example next-server). Keep that command
                // and its connected same-project runtime ancestors/descendants
                // together. Independent commands in that directory remain separate.
                owner = commandOwners[process.pid]
                var current = process
                var visited: Set<Int32> = [process.pid]
                while owner == nil, current.parentPID > 1, let parent = byPID[current.parentPID], visited.insert(parent.pid).inserted {
                    guard parent.startTime <= current.startTime, parent.userID == process.userID,
                          process.workingDirectory != nil, parent.workingDirectory == process.workingDirectory else { break }
                    owner = commandOwners[parent.pid]
                    current = parent
                }
            }
            // Keep unowned daemons separate; launchd is never an app ownership root.
            let result = owner ?? Owner(id: "process:\(process.pid):\(process.startTime.timeIntervalSince1970)", name: process.name, path: nil)
            if groups[result.id] == nil { groups[result.id] = AppGroup(id: result.id, name: result.name, bundlePath: result.path, processes: []) }
            groups[result.id]?.processes.append(process)
        }
        return groups.values.map { group in
            var group = group
            group.processes.sort { $0.residentBytes == $1.residentBytes ? $0.pid < $1.pid : $0.residentBytes > $1.residentBytes }
            return group
        }.sorted { $0.memoryBytes == $1.memoryBytes ? $0.id < $1.id : $0.memoryBytes > $1.memoryBytes }
    }
}
