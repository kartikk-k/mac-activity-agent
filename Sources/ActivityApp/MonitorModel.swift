import AppKit
import SwiftUI
import ActivityCore
import UserNotifications

struct LivePoint: Identifiable { let id = UUID(); let date: Date; let cpu: Double; let memory: Double; let download: Double }
enum Section: String, CaseIterable, Identifiable {
    case overview = "Overview", apps = "Applications", agents = "Agents", projects = "Projects", containers = "Containers", history = "History", alerts = "Alerts", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .overview: return "square.grid.2x2"; case .apps: return "square.stack.3d.up"; case .agents: return "terminal"; case .projects: return "terminal"; case .containers: return "shippingbox"; case .history: return "clock.arrow.circlepath"; case .alerts: return "bell"; case .settings: return "slider.horizontal.3" }
    }
}
// Mutable samplers are confined to this single serial utility queue.
final class SamplingWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "local.activityagent.sampling", qos: .utility)
    lazy var sampler = ProcessSampler()
    lazy var systemSampler = SystemSampler()
    lazy var history = HistoryStore(retentionDays: max(30, UserDefaults.standard.integer(forKey:"retentionDays")))
    lazy var alertEvaluator = AlertEvaluator()
    lazy var recommendations = RecommendationService()
}
@MainActor final class MonitorModel: ObservableObject {
    @Published var closeRecommendations: [CloseRecommendation] = []
    @Published var keptRunning: Set<String> = []
    @Published var suspended: Set<Int32> = []
    @Published var recommendationsOnly = false
    @Published var groups: [AppGroup] = []
    @Published var processes: [ProcessRecord] = []
    @Published var system: SystemSnapshot?
    @Published var points: [LivePoint] = []
    @Published var section: Section = .overview
    @Published var search = ""
    @Published var sort = "Memory"
    @Published var selectedGroup: String?
    @Published var showSystem = false
    @Published var paused = false
    @Published var error: String?
    @Published var sessionList: [AgentSession] = []
    @Published var listeners: [ProjectListener] = []
    @Published var docker: DockerSnapshot?
    @Published var activityAlerts: [ActivityAlert] = []
    @Published var historySamples: [HistorySample] = []
    @Published private var portsLoading = false
    @Published private var dockerLoading = false
    var servicesLoading: Bool { section == .containers ? dockerLoading : portsLoading }
    @Published var sampleMilliseconds: Double = 0
    @Published var lastUpdated: Date?
    @Published var foregroundInterval: Double = UserDefaults.standard.object(forKey:"foregroundInterval") as? Double ?? 6.0 { didSet { UserDefaults.standard.set(foregroundInterval,forKey:"foregroundInterval") } }
    @Published var backgroundInterval: Double = UserDefaults.standard.object(forKey:"backgroundInterval") as? Double ?? 15.0 { didSet { UserDefaults.standard.set(backgroundInterval,forKey:"backgroundInterval") } }
    @Published var compact: Bool = UserDefaults.standard.object(forKey:"compact") as? Bool ?? false { didSet { UserDefaults.standard.set(compact,forKey:"compact") } }
    @Published var notifyAlerts: Bool = UserDefaults.standard.object(forKey:"notifyAlerts") as? Bool ?? false { didSet { UserDefaults.standard.set(notifyAlerts,forKey:"notifyAlerts") } }
    @Published var retentionDays: Int = UserDefaults.standard.object(forKey:"retentionDays") as? Int ?? 30 { didSet { UserDefaults.standard.set(retentionDays,forKey:"retentionDays") } }
    @Published var menuMetric: String = UserDefaults.standard.object(forKey:"menuMetric") as? String ?? "CPU" { didSet { UserDefaults.standard.set(menuMetric,forKey:"menuMetric") } }
    @Published var cpuPerMac: Bool = UserDefaults.standard.object(forKey:"cpuPerMac") as? Bool ?? false { didSet { UserDefaults.standard.set(cpuPerMac,forKey:"cpuPerMac") } }
    @Published var monochrome: Bool = UserDefaults.standard.object(forKey:"monochrome") as? Bool ?? false { didSet { UserDefaults.standard.set(monochrome,forKey:"monochrome") } }
    @Published var floatWindow: Bool = UserDefaults.standard.object(forKey:"floatWindow") as? Bool ?? false { didSet { UserDefaults.standard.set(floatWindow,forKey:"floatWindow") } }
    nonisolated private let worker = SamplingWorker()
    private let projectService = ProjectService()
    private let usageService = AgentUsageService()
    @Published var usage: AgentUsageSnapshot?
    @Published var claudeUsage: AgentLocalTokenSummary?
    private var usageUpdated = Date.distantPast
    private var timer: Timer?
    private var sampling = false
    private var nextSample = Date.distantPast
    private var portsUpdated = Date.distantPast
    private var dockerUpdated = Date.distantPast
    private var sleeping = false
    private var icons: [String: NSImage] = [:]
    init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.sleeping = true } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.sleeping = false; self?.refresh(force: true) } }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.configureTimer(); self?.refresh(force: true) } }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.configureTimer() } }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [worker] _ in worker.queue.sync { worker.history.flush() } }
        for event in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            NotificationCenter.default.addObserver(forName:event,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.configureTimer() } }
        }
        keptRunning = Set(UserDefaults.standard.stringArray(forKey:"keepRunning") ?? [])
        configureTimer()
        refresh(force: true)
    }
    var mainWindowVisible: Bool { NSApp.windows.contains { $0.title == "Activity Agent" && $0.isVisible && !$0.isMiniaturized } }
    func configureTimer() {
        timer?.invalidate()
        let interval = NSApp.isActive && mainWindowVisible ? max(3, foregroundInterval) : max(10, backgroundInterval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer?.tolerance = interval * 0.2
    }
    func refreshUsage() {
        guard Date().timeIntervalSince(usageUpdated) > 30 else { return }
        usageUpdated = Date()
        Task { usage = await usageService.codexUsage(); claudeUsage = await usageService.claudeUsage() }
    }
    var visibleGroups: [AppGroup] {
        groups.filter { group in (!recommendationsOnly || closeRecommendations.contains { $0.groupID == group.id }) && (showSystem || group.bundlePath != nil || group.id.hasPrefix("command:")) && (search.isEmpty || group.name.localizedCaseInsensitiveContains(search) || group.processes.contains { $0.name.localizedCaseInsensitiveContains(search) || String($0.pid).contains(search) }) }
            .sorted { a,b in switch sort { case "CPU": return a.cpuPercent > b.cpuPercent; case "Name": return a.name.localizedStandardCompare(b.name) == .orderedAscending; case "Processes": return a.processes.count > b.processes.count; default: return a.memoryBytes > b.memoryBytes } }
    }
    func providerIcon(_ provider: AgentProvider) -> NSImage {
        let key = "provider:" + provider.rawValue
        if let icon = icons[key] { return icon }
        // Codex uses the OpenAI knot when its own application is not installed.
        let names: [AgentProvider:[String]] = [.codex:["Codex","ChatGPT"],.claude:["Claude"],.cursor:["Cursor"],.copilot:["GitHub Copilot"],.gemini:["Gemini"],.opencode:["OpenCode"],.goose:["Goose"]]
        for name in names[provider] ?? [] {
            let path = "/Applications/" + name + ".app"
            if FileManager.default.fileExists(atPath:path) { let icon = NSWorkspace.shared.icon(forFile:path);icons[key] = icon;return icon }
        }
        return NSImage(systemSymbolName:"terminal",accessibilityDescription:provider.displayName)!
    }
    func icon(_ group: AppGroup) -> NSImage {
        if let icon = icons[group.id] { return icon }
        if group.name.lowercased().contains("next-server") {
            let image = NSImage(size:NSSize(width:64,height:64),flipped:false) { rect in
                NSColor.black.setFill();NSBezierPath(ovalIn:rect.insetBy(dx:2,dy:2)).fill()
                let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:38,weight:.medium),.foregroundColor:NSColor.white]
                NSAttributedString(string:"N",attributes:attrs).draw(at:NSPoint(x:17,y:9))
                return true
            };icons[group.id] = image;return image
        }
        let image = group.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil)!
        icons[group.id] = image
        return image
    }
    func refresh(force: Bool = false) {
        guard !sampling, !sleeping, !paused, force || Date() >= nextSample else { return }
        sampling = true
        let active = NSApp.isActive && mainWindowVisible
        nextSample = Date().addingTimeInterval(active ? max(3, foregroundInterval) : max(10, backgroundInterval))
        let running = NSWorkspace.shared.runningApplications.map { RunningApplication(pid: $0.processIdentifier, name: $0.localizedName ?? "Application", bundlePath: $0.bundleURL?.path, bundleIdentifier: $0.bundleIdentifier) }
        let retention = retentionDays
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleURL?.path
        let keep = keptRunning
        worker.queue.async { [self] in
            let begin = Date()
            let records = worker.sampler.sample()
            let grouped = ProcessGrouper.group(records, applications: running)
            let snapshot = worker.systemSampler.sample()
            let metrics = grouped.map { HistoryAppMetric(id: $0.id, name: $0.name, cpuPercent: $0.cpuPercent, memoryBytes: $0.memoryBytes, diskReadBytes: $0.diskReadBytes, diskWriteBytes: $0.diskWriteBytes) }
            worker.history.retentionDays = retention
            worker.history.record(system: snapshot, apps: metrics.filter { metric in grouped.contains { $0.id == metric.id && ($0.bundlePath != nil || $0.id.hasPrefix("command:")) } })
            let alerts = worker.alertEvaluator.evaluate(apps: metrics) + worker.alertEvaluator.evaluate(system: snapshot)
            let sessions = AgentService.sessions(from: records)
            let suggestions = worker.recommendations.evaluate(groups: grouped.filter { ($0.isApplication || $0.isCommandGroup) && !($0.bundlePath?.hasPrefix("/System/Library/") ?? false) && !$0.processes.contains { $0.pid == ProcessInfo.processInfo.processIdentifier } }, frontmostBundlePath: frontmost, keepRunningIDs: keep)
            let elapsed = Date().timeIntervalSince(begin) * 1000
            Task { @MainActor in
                self.closeRecommendations = suggestions.filter { !self.keptRunning.contains($0.groupID) }
                self.suspended = Set(records.filter(\.isStopped).map(\.pid))
                self.processes = records; self.groups = grouped; self.system = snapshot
                self.sessionList = sessions; self.sampleMilliseconds = elapsed; self.lastUpdated = Date()
                self.points.append(LivePoint(date: snapshot.timestamp, cpu: snapshot.cpuPercent, memory: Double(snapshot.memoryUsed) / max(1,Double(snapshot.memoryTotal)) * 100, download:Double(snapshot.networkReceivedBytes)))
                if self.points.count > 600 { self.points.removeFirst(self.points.count - 600) }
                self.activityAlerts.insert(contentsOf: alerts, at: 0)
                if self.activityAlerts.count > 100 { self.activityAlerts = Array(self.activityAlerts.prefix(100)) }
                if self.notifyAlerts { self.deliver(alerts) }
                self.sampling = false
                if self.mainWindowVisible && NSApp.isActive {
                    if self.section == .agents { self.refreshUsage() }
                    if self.section == .overview || self.section == .projects || self.section == .containers || self.section == .apps || self.section == .agents { self.refreshServices() }
                }
            }
        }
    }
    func refreshServices(force: Bool = false) {
        if section == .containers {
            guard !dockerLoading, force || Date().timeIntervalSince(dockerUpdated) > 30 else { return }
            dockerLoading = true; dockerUpdated = Date()
            Task { docker = await DockerService.snapshot(); dockerLoading = false }
        } else {
            guard !portsLoading, force || Date().timeIntervalSince(portsUpdated) > 30 else { return }
            portsLoading = true; portsUpdated = Date()
            let records = processes
            Task { listeners = await projectService.listeners(processes:records,forceRefresh:force); portsLoading = false }
        }
    }
    func loadHistory(days: Int = 1) {
        worker.queue.async { [self] in
            worker.history.flush()
            let samples = worker.history.samples(since: Date().addingTimeInterval(-Double(days) * 86400))
            Task { @MainActor in self.historySamples = samples }
        }
    }
    func cpu(_ value: Double) -> String { String(format: "%.1f%%", value / (cpuPerMac ? Double(ProcessInfo.processInfo.activeProcessorCount) : 1)) }
    func ports(for records:[ProcessRecord]) -> [Int] {
        let byPID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return Array(Set(listeners.filter { listener in byPID[listener.pid].map { listener.matches($0) } ?? false }.map(\.port))).sorted()
    }
    var uniqueAgentProcesses: [ProcessRecord] { AgentService.uniqueProcesses(sessions: sessionList, processes: processes) }
    func keepRunning(_ group:AppGroup) {
        if keptRunning.contains(group.id) {keptRunning.remove(group.id)} else {keptRunning.insert(group.id)}
        UserDefaults.standard.set(Array(keptRunning),forKey:"keepRunning")
        closeRecommendations.removeAll { keptRunning.contains($0.groupID) }
    }
    func suspend(_ records:[ProcessRecord],resume:Bool) {
        let allowed = records.filter { $0.pid > 1 && $0.pid != ProcessInfo.processInfo.processIdentifier && $0.userID == getuid() }
        worker.queue.async { [self] in
            let live = Dictionary(uniqueKeysWithValues: worker.sampler.sample().map { ($0.pid,$0) })
            var changed: [Int32] = []
            for record in allowed {
                guard let current = live[record.pid],current.startTime == record.startTime,current.executablePath == record.executablePath else { continue }
                if kill(record.pid,resume ? SIGCONT : SIGSTOP) == 0 {changed.append(record.pid)}
            }
            Task { @MainActor in
                if resume { self.suspended.subtract(changed) } else { self.suspended.formUnion(changed) }
                self.refresh(force:true)
            }
        }
    }
    func terminate(_ records: [ProcessRecord], force: Bool) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let allowed = records.filter { $0.pid > 1 && $0.pid != ownPID && $0.userID == getuid() }
        worker.queue.async { [self] in
            let live = Dictionary(uniqueKeysWithValues: worker.sampler.sample().map { ($0.pid, $0) })
            var failed = 0
            for record in allowed.reversed() {
                guard let current = live[record.pid], current.startTime == record.startTime, current.executablePath == record.executablePath else { continue }
                if kill(record.pid, force ? SIGKILL : SIGTERM) != 0 { failed += 1 }
                else if !force && current.isStopped { _ = kill(record.pid, SIGCONT) }
            }
            Task { @MainActor in
                if failed > 0 { self.error = "Could not stop \(failed) processes. They may require a different user or may have already exited." }
                self.refresh(force: true)
            }
        }
    }
    private func deliver(_ alerts: [ActivityAlert]) {
        for alert in alerts {
            let content = UNMutableNotificationContent(); content.title = alert.title; content.body = alert.message
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
    func setNotifications(_ enabled: Bool) {
        notifyAlerts = enabled
        if enabled { UNUserNotificationCenter.current().requestAuthorization(options: [.alert,.sound]) { _,_ in } }
    }
}
func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory) }
