import SwiftUI
import AppKit
import ActivityCore
import ServiceManagement

struct DashboardView: View {
    @EnvironmentObject var model: MonitorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var pending: [ProcessRecord] = []
    @State private var confirm = false
    @State private var force = false
    @State private var pauseConfirm = false
    @State private var historyDays = 1
    @State private var expanded = Set<String>()
    @State private var settingsError: String?
    var body: some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:28) {
                HStack(spacing:10) {
                    Image(nsImage:NSApp.applicationIconImage).resizable().aspectRatio(contentMode:.fit).frame(width:34,height:34).fixedSize()
                    Text("Activity Agent").font(.system(size:14,weight:.medium))
                }.padding(.horizontal,12).padding(.top,52)
                VStack(alignment:.leading,spacing:6) {
                    ForEach([Section.overview,.apps,.agents,.projects,.containers]) { sidebarItem($0) }
                    Color.clear.frame(height:20)
                    ForEach([Section.history,.alerts,.settings]) { sidebarItem($0) }
                }
                Spacer()
                VStack(alignment:.leading,spacing:8) {
                    HStack(spacing:7) { Circle().fill(model.paused ? Color.orange : Color.primary.opacity(0.65)).frame(width:5,height:5); Text(model.paused ? "Paused" : "Monitoring locally").font(.caption) }
                    Text("\(model.processes.count) processes · \(model.groups.filter { $0.bundlePath != nil }.count) apps").font(.caption2).foregroundStyle(.secondary)
                }.padding(12).padding(.bottom,16)
            }.padding(.horizontal,12).frame(width:196).padding(10)
            ScrollView {
                VStack(alignment:.leading,spacing:26) {
                    header
                    Group { switch model.section {
                    case .overview: overview
                    case .apps: applicationList
                    case .agents: agentList
                    case .projects: projectList
                    case .containers: containerList
                    case .history: historyView
                    case .alerts: alertsView
                    case .settings: settingsView
                    }}.id(model.section).transition(.opacity).animation(reduceMotion ? nil : .easeInOut(duration:0.2),value:model.section)
                }.padding(.horizontal,30).padding(.top,54).padding(.bottom,30).frame(maxWidth:1500,alignment:.leading).frame(maxWidth:.infinity)
            }
        }
        .ignoresSafeArea(.container,edges:.top)
        .background(NativeWindowBackdrop().ignoresSafeArea())
        .tint(.primary)
        .onOpenURL { url in
            guard url.scheme == "activityagent",let host = url.host else { return }
            let routes: [String:Section] = ["overview":.overview,"apps":.apps,"agents":.agents,"projects":.projects,"containers":.containers,"history":.history,"alerts":.alerts,"settings":.settings]
            if let section = routes[host] {model.section = section}
            if let value = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name == "pid"})?.value,let pid = Int32(value),let group = model.groups.first(where:{$0.processes.contains{$0.pid == pid}}) {model.selectedGroup = group.id;model.section = .apps}
        }
        .onChange(of:model.section) { _,section in
            if section == .overview || section == .projects || section == .containers || section == .apps || section == .agents { model.refreshServices(force:true) }
            if section == .agents { model.refreshUsage() }
            if section == .history { model.loadHistory(days:historyDays) }
        }
        .onChange(of:model.foregroundInterval) { _,_ in model.configureTimer() }
        .onChange(of:model.backgroundInterval) { _,_ in model.configureTimer() }
        .onChange(of:model.floatWindow) { _,value in NSApp.windows.filter { $0.title == "Activity Agent" }.forEach { $0.level = value ? .floating : .normal } }
        .confirmationDialog(force ? "Force quit \(pending.count) processes?" : "Quit \(pending.count) processes?",isPresented:$confirm,titleVisibility:.visible) {
            Button(force ? "Force Quit" : "Quit",role:.destructive) { model.terminate(pending,force:force) }
            Button("Cancel",role:.cancel) { pending = [] }
        } message: { Text("Unsaved work may be lost. Only processes from the selected app or session will be signalled.") }
        .alert("Pause these processes?",isPresented:$pauseConfirm) {
            Button("Pause") { model.suspend(pending,resume:false) }
            Button("Cancel",role:.cancel) {}
        } message: { Text("Pausing stops CPU work, but keeps memory allocated. Servers will stop responding until resumed. This does not clear swap.") }
        .alert("Activity Agent",isPresented:Binding(get:{model.error != nil || settingsError != nil},set:{if !$0 {model.error = nil;settingsError = nil}})) { Button("OK") {model.error = nil;settingsError = nil} } message:{Text(model.error ?? settingsError ?? "")}
    }
    private func sidebarItem(_ section:Section)->some View {
        Button { model.section = section } label: {
            HStack(spacing:11) { Image(systemName:section.symbol).font(.system(size:15,weight:.regular)).frame(width:20).foregroundStyle(.secondary);Text(section.rawValue).font(.system(size:13,weight:model.section == section ? .semibold : .regular));Spacer() }.padding(.horizontal,12).padding(.vertical,11).contentShape(RoundedRectangle(cornerRadius:12))
        }.buttonStyle(.plain).background(model.section == section ? Color.primary.opacity(0.08) : Color.clear,in:RoundedRectangle(cornerRadius:12))
    }
    private var header: some View {
        HStack(alignment:.top,spacing:16) {
            VStack(alignment:.leading,spacing:6) {
                Text(model.section.rawValue).font(.system(size:28,weight:.medium))
                Text(subtitle).foregroundStyle(.secondary).font(.system(size:13))
            }
            Spacer(minLength:12)
            HStack(spacing:6) {
                headerButton(model.paused ? "play" : "pause",help:model.paused ? "Resume monitoring" : "Pause monitoring") {model.paused.toggle()}
                headerButton("arrow.clockwise",help:"Refresh") {model.refresh(force:true);model.refreshServices(force:true)}
                headerButton("square.and.arrow.up",help:"Export overview") {exportImage()}
                HStack(spacing:6) {
                    Circle().fill(model.paused ? Color.orange : Color.primary.opacity(0.7)).frame(width:5,height:5)
                    Text(model.paused ? "Paused" : "Live").font(.system(size:11,weight:.medium))
                }.padding(.horizontal,11).frame(height:30).glassPill().padding(.leading,6)
            }.fixedSize().padding(.top,2)
        }
    }
    private func headerButton(_ symbol:String,help:String,action:@escaping ()->Void)->some View {
        Button(action:action) {Image(systemName:symbol).font(.system(size:13,weight:.regular)).frame(width:30,height:30).contentShape(Rectangle())}.buttonStyle(.plain).foregroundStyle(.secondary).help(help)
    }
    private var subtitle: String {
        switch model.section {
        case .overview: return "A clear view of what your Mac is doing."
        case .apps: return "Applications and their helpers, together."
        case .agents: return "Coding sessions and the processes they started."
        case .projects: return "Listening ports, their processes, and their project folders."
        case .containers: return "Resource usage from your local Docker engine."
        case .history: return "Your activity, stored only on this Mac."
        case .alerts: return "Sustained resource use that deserves a closer look."
        case .settings: return "Make the monitor work quietly for you."
        }
    }
    private var overview: some View {
        VStack(alignment:.leading,spacing:24) {
            if let s = model.system {
                HStack(spacing:14) {
                    MetricCard(title:"Processor",value:String(format:"%.1f%%",s.cpuPercent),detail:"Across all cores",symbol:"cpu",color:.primary,values:Array(model.points.suffix(60).map(\.cpu)))
                    MetricCard(title:"Memory",value:bytes(s.memoryUsed),detail:"of \(bytes(s.memoryTotal)) physical",symbol:"memorychip",color:.primary,values:Array(model.points.suffix(60).map(\.memory)))
                    MetricCard(title:"Network",value:bytes(s.networkReceivedBytes)+"/s",detail:"↑ \(bytes(s.networkSentBytes))/s upload",symbol:"network",color:.primary,values:Array(model.points.suffix(60).map(\.download)))
                }
                HStack(alignment:.top,spacing:18) {
                    VStack(alignment:.leading,spacing:16) {
                        cardHeading("Memory composition", "Physical memory")
                        MemoryDotBar(total:s.memoryTotal,used:s.memoryUsed,wired:s.memoryWired,compressed:s.memoryCompressed).frame(height:30)
                        HStack { legend("Wired",bytes(s.memoryWired),.primary); Spacer(); legend("Compressed",bytes(s.memoryCompressed),.secondary); Spacer(); legend("Cached",bytes(s.memoryCached),.gray) }
                        Divider()
                        HStack { Text("Swap used").foregroundStyle(.secondary); Spacer(); Text(bytes(s.swapUsed)).monospacedDigit();Button("Reclaim memory…") {model.section = .apps;model.recommendationsOnly = true}.buttonStyle(.plain).foregroundStyle(.secondary) }.font(.caption)
                        Text("macOS manages swap. Quitting an unneeded app releases its memory; pausing does not.").font(.caption2).foregroundStyle(.tertiary)
                    }.padding(20).frame(maxHeight:.infinity,alignment:.top).cardSurface()
                    VStack(alignment:.leading,spacing:16) {
                        cardHeading("System",ProcessInfo.processInfo.hostName)
                        infoRow("Thermal state",s.thermalState)
                        infoRow("GPU",s.gpuPercent.map{String(format:"%.0f%%",$0)} ?? "Unavailable")
                        infoRow("Battery",s.batteryPercent.map{String(format:"%.0f%%",$0)+(s.isCharging ? " · charging" : "")} ?? "On AC power / unavailable")
                        infoRow("Uptime",duration(s.uptime))
                        infoRow("Disk read / write",bytes(s.diskReadBytes)+" / "+bytes(s.diskWriteBytes)+" per second")
                    }.padding(20).frame(width:280).frame(maxHeight:.infinity,alignment:.top).cardSurface()
                }.fixedSize(horizontal:false,vertical:true)
            }
            VStack(alignment:.leading,spacing:12) {
                HStack { cardHeading("Applications","Largest memory footprint"); Spacer(); Button("View all") {model.section = .apps}.buttonStyle(.plain).foregroundStyle(.secondary) }
                ForEach(model.groups.filter{$0.bundlePath != nil || $0.id.hasPrefix("command:")}.sorted{$0.memoryBytes > $1.memoryBytes}.prefix(7)) { group in appRow(group,canExpand:false) }
            }.padding(20).cardSurface()
            HStack(spacing:8) { Image(systemName:"leaf").foregroundStyle(.green); Text("Adaptive sampling · every 3 seconds here, \(Int(model.backgroundInterval)) seconds in the background").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var applicationList: some View {
        VStack(spacing:18) {
            HStack {
                HStack { Image(systemName:"magnifyingglass").foregroundStyle(.secondary); TextField("Search apps, processes, or PID",text:$model.search).textFieldStyle(.plain) }.padding(10).background(.quaternary.opacity(0.5),in:RoundedRectangle(cornerRadius:10))
                Toggle("System processes",isOn:$model.showSystem).toggleStyle(.checkbox)
                Picker("Sort",selection:$model.sort) { ForEach(["Memory","CPU","Name","Processes"],id:\.self) {Text($0)} }.frame(width:170)
            }
            HStack {
                Toggle("Recommended for closing",isOn:$model.recommendationsOnly).toggleStyle(.checkbox)
                Text("\(model.closeRecommendations.count) suggestions").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Ports refresh every 30s").font(.caption).foregroundStyle(.tertiary)
            }
            if model.recommendationsOnly && model.visibleGroups.isEmpty {
                Text("No suggestions yet. Apps need at least one hour running and 15 minutes of observed low CPU with no disk activity. Your active app and anything marked Keep running are excluded.").font(.callout).foregroundStyle(.secondary).padding(20).cardSurface()
            }
            HStack(spacing:12) { Text("APPLICATION / PROCESS"); Spacer(); Text("CPU").frame(width:85,alignment:.trailing); Text("MEMORY").frame(width:110,alignment:.trailing); Color.clear.frame(width:46) }.font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary).padding(.horizontal,18)
            LazyVStack(spacing:2) {
                ForEach(model.visibleGroups) { group in
                    appRow(group,canExpand:true)
                    if expanded.contains(group.id) || model.selectedGroup == group.id {
                        ForEach(group.processes.sorted{$0.residentBytes > $1.residentBytes}) { process in
                            HStack(spacing:12) { Text(process.name).lineLimit(1); portLabels([process]); Spacer(); Text(model.cpu(process.cpuPercent)).frame(width:85,alignment:.trailing); Text(bytes(process.residentBytes)).frame(width:110,alignment:.trailing); Button {requestQuit([process])} label:{Image(systemName:"xmark.circle")}.buttonStyle(.plain).foregroundStyle(.secondary).frame(width:46) }.font(.caption).padding(.vertical,8).padding(.leading,60).padding(.trailing,12).help(process.executablePath)
                        }
                    }
                }
            }.animation(reduceMotion || scenePhase != .active || !NSApp.isActive ? nil : .easeInOut(duration:0.25),value:model.visibleGroups.map(\.id)).padding(6).cardSurface()
            Text("CPU is \(model.cpuPerMac ? "a share of total Mac capacity" : "per core; 100% equals one full core"). Memory uses physical footprint where available, with resident memory as a fallback.").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    private func portLabels(_ records:[ProcessRecord])->some View {
        let ports = model.ports(for:records)
        return ViewThatFits(in:.horizontal) {
            portBadges(ports)
            HStack(spacing:5) {portBadges(Array(ports.prefix(2)));if ports.count > 2 {Text(verbatim:"+" + String(ports.count-2)).font(.system(size:10,weight:.medium,design:.monospaced)).foregroundStyle(.secondary)}}
        }.help(ports.isEmpty ? "No listening TCP ports" : "Listening ports: " + ports.map(String.init).joined(separator:", "))
    }
    private func portBadges(_ ports:[Int])->some View {
        HStack(spacing:5) {ForEach(ports,id:\.self) {port in
            Text(verbatim:String(port)).font(.system(size:11,weight:.medium,design:.monospaced)).foregroundStyle(.primary.opacity(0.8)).padding(.horizontal,5).padding(.vertical,2).background(Color.primary.opacity(0.06),in:RoundedRectangle(cornerRadius:4)).fixedSize()
        }}.fixedSize(horizontal:true,vertical:false)
    }
    private func appRow(_ group:AppGroup,canExpand:Bool) -> some View {
        HStack(spacing:12) {
            if canExpand { Button {withAnimation(reduceMotion ? nil : .easeInOut(duration:0.2)) {if expanded.contains(group.id) || model.selectedGroup == group.id {expanded.remove(group.id);model.selectedGroup = nil} else {expanded.insert(group.id)}}} label:{Image(systemName:expanded.contains(group.id) || model.selectedGroup == group.id ? "chevron.down" : "chevron.right").font(.system(size:9,weight:.bold)).frame(width:12)}.buttonStyle(.plain) }
            Image(nsImage:model.icon(group)).resizable().aspectRatio(contentMode:.fit).frame(width:32,height:32).fixedSize()
            VStack(alignment:.leading,spacing:4) {Text(group.name).font(.system(size:13,weight:.medium)).lineLimit(1);HStack(spacing:8) { Text("\(group.processes.count) processes").font(.caption).foregroundStyle(.secondary).fixedSize();portLabels(group.processes);if model.keptRunning.contains(group.id) {Image(systemName:"pin.fill").font(.caption2).foregroundStyle(.secondary)} }
                if let suggestion = model.closeRecommendations.first(where:{$0.groupID == group.id}) {Text(suggestion.reason).font(.caption2).foregroundStyle(.secondary)}
                if group.processes.contains(where:{($0.isStopped || model.suspended.contains($0.pid))}) {Text("Paused · memory retained").font(.caption2).foregroundStyle(.orange)}}
            Spacer()
            Text(model.cpu(group.cpuPercent)).contentTransition(.opacity).environment(\.contentTransitionAddsDrawingGroup,true).animation(reduceMotion || scenePhase != .active || !NSApp.isActive ? nil : .easeOut(duration:0.18),value:model.cpu(group.cpuPercent)).font(.system(size:12,design:.monospaced)).foregroundStyle(group.cpuPercent > 80 ? .orange : .secondary).frame(width:85,alignment:.trailing)
            Text(bytes(group.memoryBytes)).contentTransition(.opacity).environment(\.contentTransitionAddsDrawingGroup,true).animation(reduceMotion || scenePhase != .active || !NSApp.isActive ? nil : .easeOut(duration:0.18),value:bytes(group.memoryBytes)).font(.system(size:13,weight:.semibold,design:.rounded)).monospacedDigit().frame(width:110,alignment:.trailing)
            if canExpand { Menu {
                Button(model.keptRunning.contains(group.id) ? "Remove Keep running" : "Keep running") {model.keepRunning(group)}
                if group.processes.contains(where:{($0.isStopped || model.suspended.contains($0.pid))}) {Button("Resume") {model.suspend(group.processes,resume:true)}}
                else {Button("Pause…") {pending = group.processes;pauseConfirm = true}}
                Divider()
                Button("Quit…") {requestQuit(group.processes)};Button("Force Quit…",role:.destructive) {requestQuit(group.processes,force:true)};if let path = group.bundlePath {Button("Show in Finder") {NSWorkspace.shared.selectFile(path,inFileViewerRootedAtPath:"")}}} label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width:46) }
        }.padding(.horizontal,12).padding(.vertical,model.compact ? 7 : 12).background(model.selectedGroup == group.id ? Color.primary.opacity(0.055) : Color.clear,in:RoundedRectangle(cornerRadius:10))
    }
    private var agentList: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { MetricSmall(label:"Sessions",value:"\(model.sessionList.count)"); MetricSmall(label:"Memory",value:bytes(model.uniqueAgentProcesses.reduce(0){$0+$1.residentBytes})); MetricSmall(label:"CPU",value:model.cpu(model.uniqueAgentProcesses.reduce(0){$0+$1.cpuPercent})) }
            if model.sessionList.isEmpty { empty("No CLI sessions detected", "Supported native agent executables appear automatically while running.","terminal") }
            if let summary = model.claudeUsage {
                VStack(alignment:.leading,spacing:12) {
                    HStack {Image(nsImage:model.providerIcon(.claude)).resizable().aspectRatio(contentMode:.fit).frame(width:24,height:24).fixedSize();Text("Claude · observed tokens").font(.headline)}
                    HStack { MetricSmall(label:"Today · partial",value:summary.todayTokens.formatted());MetricSmall(label:"Last 7 days · partial",value:summary.weekTokens.formatted()) }
                    Text("Partial totals from recent local logs, including input, output, and cache tokens. Not plan usage or remaining allowance.").font(.caption).foregroundStyle(.secondary)
                }.padding(20).cardSurface()
            }
            if let usage = model.usage {
                VStack(alignment:.leading,spacing:14) {
                    HStack { HStack {Image(nsImage:model.providerIcon(.codex)).resizable().aspectRatio(contentMode:.fit).frame(width:24,height:24).fixedSize();Text("Codex plan observation").font(.headline)}; Spacer(); Text(usage.observedAt,style:.relative).font(.caption).foregroundStyle(.secondary) }
                    HStack(spacing:24) {
                        if let window = usage.primary { usageWindow(window,label:windowTitle(window)) }
                        if let window = usage.secondary { usageWindow(window,label:windowTitle(window)) }
                        if let tokens = usage.sessionTokens { MetricSmall(label:"Latest session tokens",value:tokens.formatted()) }
                    }
                    Text("From recent local session logs. This is the last recorded observation, not a live account balance.").font(.caption).foregroundStyle(.secondary)
                }.padding(20).cardSurface()
            }
            ForEach(model.sessionList) { session in
                VStack(alignment:.leading,spacing:16) {
                    HStack { Image(nsImage:model.providerIcon(session.provider)).resizable().aspectRatio(contentMode:.fit).frame(width:32,height:32).fixedSize(); VStack(alignment:.leading,spacing:4){Text(session.provider.displayName).font(.headline);Text(session.projectName).font(.caption).foregroundStyle(.secondary)}; Text(session.state.rawValue).font(.caption).padding(.horizontal,9).padding(.vertical,4).background(.purple.opacity(0.1),in:Capsule());Spacer();Text(bytes(session.residentBytes)).monospacedDigit();Button("Quit session…") {requestQuit(model.processes.filter{session.processIDs.contains($0.pid)})} }
                    Text(session.projectPath ?? "Project directory unavailable").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Divider()
                    ForEach(model.processes.filter{session.processIDs.contains($0.pid)}) { process in HStack {Image(systemName:process.name.contains("mcp") ? "puzzlepiece.extension" : "terminal").foregroundStyle(.secondary);Text(process.name);Spacer();portLabels([process]);Text(model.cpu(process.cpuPercent)).frame(width:75,alignment:.trailing);Text(bytes(process.residentBytes)).frame(width:100,alignment:.trailing)}.font(.caption) }
                }.padding(20).cardSurface()
            }
            Text("Activity labels reflect observed CPU use. Waiting for input and reasoning cannot be reliably inferred from CPU alone.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var projectList: some View {
        VStack(alignment:.leading,spacing:16) {
            if model.servicesLoading {ProgressView("Reading local ports…")}
            if model.listeners.isEmpty && !model.servicesLoading {empty("No visible listening ports","Only ports accessible to your user are listed.","network")}
            ForEach(model.listeners) { listener in
                HStack(spacing:18) {
                    Text(String(listener.port)).font(.system(.title3,design:.monospaced,weight:.medium)).foregroundStyle(.primary).frame(width:70)
                    VStack(alignment:.leading,spacing:5) {Text(listener.projectPath.map{URL(fileURLWithPath:$0).lastPathComponent} ?? listener.processName).font(.headline);Text("\(listener.processName) · PID \(listener.pid) · \(listener.address)").font(.caption).foregroundStyle(.secondary);if let path = listener.projectPath {Text(path).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)}}
                    Spacer();Button("Stop…") {requestQuit(model.processes.filter{listener.matches($0)})}.disabled(!model.processes.contains{listener.matches($0)})
                }.padding(20).cardSurface()
            }
            Text("Ports refresh only while this view is open, at most once every 30 seconds.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var containerList: some View {
        VStack(alignment:.leading,spacing:16) {
            if model.servicesLoading {ProgressView("Reading Docker…")}
            if let docker = model.docker {
                if let reason = docker.unavailableReason {empty("Docker unavailable",reason,"shippingbox")}
                else if docker.containers.isEmpty {empty("No running containers","Start a container to see its resource usage here.","shippingbox")}
                ForEach(docker.containers) { container in
                    VStack(alignment:.leading,spacing:14) {HStack {Label(container.name,systemImage:"shippingbox").font(.headline);Spacer();Text(String(format:"%.1f%% CPU",container.cpuPercent)).monospacedDigit()};infoRow("Memory",container.memoryUsage);infoRow("Network I/O",container.networkIO);infoRow("Disk I/O",container.blockIO)}.padding(20).cardSurface()
                }
            }
        }
    }
    private var historyView: some View {
        VStack(alignment:.leading,spacing:20) {
            Picker("Range",selection:$historyDays) {Text("24 hours").tag(1);Text("7 days").tag(7);Text("30 days").tag(30);Text("90 days").tag(90);Text("Year").tag(365)}.pickerStyle(.segmented).onChange(of:historyDays){_,value in model.loadHistory(days:value)}
            Text("History is collected as you use the app. Past activity cannot be reconstructed.").font(.callout).foregroundStyle(.secondary)
            if model.historySamples.isEmpty {empty("History starts here","Keep Activity Agent running to build a local timeline.","clock")}
            else {historyCharts}
        }
    }
    private var historyCharts: some View {
        VStack(alignment:.leading,spacing:24) {
            VStack(alignment:.leading,spacing:16) {
                HStack {Text("Processor · total capacity").font(.headline);Spacer();Text("0–100% · latest " + String(format:"%.1f%%",model.historySamples.last?.system.cpuPercent ?? 0)).font(.caption).foregroundStyle(.secondary)}
                SoftTrendGraph(values:model.historySamples.map { $0.system.cpuPercent },showsRange:true).frame(height:180)
                historyRangeCaption
            }.padding(22).cardSurface()
            VStack(alignment:.leading,spacing:16) {
                HStack {Text("Memory").font(.headline);Spacer();Text("0–" + bytes(model.system?.memoryTotal ?? 0) + " · latest " + bytes(model.historySamples.last?.system.memoryUsed ?? 0)).font(.caption).foregroundStyle(.secondary)}
                SoftTrendGraph(values:model.historySamples.map { Double($0.system.memoryUsed)/1_073_741_824 },ceiling:Double(model.system?.memoryTotal ?? 1)/1_073_741_824,showsRange:true).frame(height:180)
                historyRangeCaption
            }.padding(22).cardSurface()
            VStack(alignment:.leading,spacing:16) {
                Text("Applications · average observed memory").font(.headline)
                ForEach(historyAppAverages.prefix(12),id:\.0) { item in HStack {Text(item.0);Spacer();Text(bytes(item.1)).monospacedDigit()}.font(.callout) }
            }.padding(22).cardSurface()
            if let first = model.historySamples.first,let last = model.historySamples.last {
                HStack {Text(first.timestamp,format:.dateTime.month(.abbreviated).day().hour().minute());Spacer();Text(last.timestamp,format:.dateTime.month(.abbreviated).day().hour().minute())}.font(.caption).foregroundStyle(.secondary)
            }
            Text("\(model.historySamples.count) samples · one per minute for 24 hours, hourly after that").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var historyRangeCaption: some View {
        HStack {
            if let first = model.historySamples.first,let last = model.historySamples.last {
                Text(first.timestamp,format:.dateTime.month(.abbreviated).day().hour().minute())
                Spacer()
                Text(last.timestamp,format:.dateTime.month(.abbreviated).day().hour().minute())
            }
        }.font(.caption2).monospacedDigit().foregroundStyle(.secondary)
    }
    private var historyAppAverages: [(String,UInt64)] {
        var totals: [String:(UInt64,UInt64)] = [:]
        for sample in model.historySamples { for app in sample.apps { let old = totals[app.name] ?? (0,0);totals[app.name] = (old.0 + app.memoryBytes,old.1 + 1) } }
        return totals.map { ($0.key,$0.value.0 / max(1,$0.value.1)) }.sorted { $0.1 > $1.1 }
    }
    private func windowTitle(_ window:AgentUsageWindow)->String {
        guard let minutes = window.windowMinutes else {return "Usage window"}
        if minutes == 10080 {return "Weekly window"}
        if minutes >= 1440 {return "\(minutes/1440)-day window"}
        if minutes >= 60 {return "\(minutes/60)-hour window"}
        return "\(minutes)-minute window"
    }
    private func usageWindow(_ window:AgentUsageWindow,label:String)->some View {
        HStack(spacing:14) {
            ZStack { Circle().stroke(.quaternary,lineWidth:7);Circle().trim(from:0,to:max(0,min(1,(100-window.usedPercent)/100))).stroke(.primary,style:StrokeStyle(lineWidth:5,lineCap:.round,dash:[1,5])).rotationEffect(.degrees(-90));Text(String(format:"%.0f%%",100-window.usedPercent)).font(.system(.body,design:.rounded,weight:.semibold)) }.frame(width:64,height:64)
            VStack(alignment:.leading,spacing:5) {Text(label).font(.callout.weight(.medium));Text("remaining").font(.caption).foregroundStyle(.secondary);if let reset = window.resetsAt {Text(resetLabel(reset)).font(.caption).foregroundStyle(.secondary)} }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private var alertsView: some View {
        VStack(alignment:.leading,spacing:18) {
            Toggle("Show macOS notifications",isOn:Binding(get:{model.notifyAlerts},set:{model.setNotifications($0)}))
            if model.activityAlerts.isEmpty {empty("Nothing needs your attention","Sustained high CPU, memory growth, and heavy disk use will appear here.","checkmark.shield")}
            ForEach(model.activityAlerts) { alert in
                VStack(alignment:.leading,spacing:8) {HStack {Text(alert.title).font(.headline);Spacer();Text(alert.timestamp,style:.time).font(.caption).foregroundStyle(.secondary)};Text(alert.message).font(.callout).foregroundStyle(.secondary)}.padding(20).cardSurface()
            }
        }
    }
    private var settingsView: some View {
        VStack(alignment:.leading,spacing:24) {
            settingsCard("Efficiency",symbol:"leaf") {
                Picker("Visible refresh",selection:$model.foregroundInterval) {Text("3 seconds · responsive").tag(3.0);Text("6 seconds · balanced").tag(6.0);Text("10 seconds · low power").tag(10.0)}
                Picker("Background refresh",selection:$model.backgroundInterval) {Text("10 seconds").tag(10.0);Text("15 seconds · balanced").tag(15.0);Text("30 seconds · low power").tag(30.0);Text("60 seconds · minimal").tag(60.0)}
                Text("Smooth transitions run only when readings change. Slower refresh uses less CPU. Sampling pauses while your Mac sleeps; background service checks are suspended.").font(.caption).foregroundStyle(.secondary)
            }
            settingsCard("Appearance",symbol:"paintpalette") {
                Toggle("Compact application rows",isOn:$model.compact)
                Toggle("Keep window above other windows",isOn:$model.floatWindow)
                Toggle("Show app CPU as a percentage of this Mac",isOn:$model.cpuPerMac)
                Picker("Menu bar reading",selection:$model.menuMetric){Text("CPU").tag("CPU");Text("Memory").tag("Memory");Text("Download speed").tag("Network")}
            }
            settingsCard("History & startup",symbol:"clock") {
                Picker("Keep history",selection:$model.retentionDays){Text("30 days").tag(30);Text("90 days").tag(90);Text("6 months").tag(180);Text("1 year").tag(365)}
                Button(SMAppService.mainApp.status == .enabled ? "Disable launch at login" : "Enable launch at login") {do {if SMAppService.mainApp.status == .enabled {try SMAppService.mainApp.unregister()} else {try SMAppService.mainApp.register()}} catch {settingsError = error.localizedDescription}}
                Text("No telemetry, no account, no cloud storage. Monitoring data remains on this Mac.").font(.caption).foregroundStyle(.secondary)
            }
            settingsCard("Hardware readings",symbol:"desktopcomputer") {Text("Temperature sensors, fan control, per-app audio, per-app GPU / Neural Engine attribution, and Bluetooth battery readings are not connected in this build. No elevated helper is installed.").font(.callout).foregroundStyle(.secondary)}
        }
    }
    private func settingsCard<Content:View>(_ title:String,symbol:String,@ViewBuilder content:()->Content)->some View {VStack(alignment:.leading,spacing:18){Label(title,systemImage:symbol).font(.headline);content()}.padding(22).frame(maxWidth:.infinity,alignment:.leading).cardSurface()}
    private func requestQuit(_ records:[ProcessRecord],force:Bool = false) {pending = records;self.force = force;confirm = true}
    private func cardHeading(_ title:String,_ subtitle:String) -> some View {VStack(alignment:.leading,spacing:4){Text(title).font(.system(size:14,weight:.semibold));Text(subtitle).font(.caption).foregroundStyle(.secondary)}}
    private func legend(_ title:String,_ value:String,_ color:Color)->some View {VStack(alignment:.leading,spacing:5){HStack(spacing:5){Circle().fill(color).frame(width:5,height:5);Text(title).foregroundStyle(.secondary)}.font(.caption2);Text(value).font(.caption.weight(.medium)).monospacedDigit()}}
    private func infoRow(_ title:String,_ value:String)->some View {HStack{Text(title).foregroundStyle(.secondary);Spacer();Text(value).multilineTextAlignment(.trailing).monospacedDigit().contentTransition(.opacity).environment(\.contentTransitionAddsDrawingGroup,true).animation(reduceMotion || scenePhase != .active || !NSApp.isActive ? nil : .easeOut(duration:0.18),value:value)}.font(.caption)}
    private func empty(_ title:String,_ detail:String,_ symbol:String)->some View {VStack(spacing:12){Image(systemName:symbol).font(.system(size:32,weight:.light)).foregroundStyle(.secondary);Text(title).font(.headline);Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)}.frame(maxWidth:.infinity).padding(.vertical,70).cardSurface()}
    private func resetLabel(_ date:Date)->String {
        guard date > Date() else {return "Awaiting fresh usage"}
        let formatter = DateComponentsFormatter();formatter.allowedUnits = [.day,.hour,.minute];formatter.unitsStyle = .abbreviated;formatter.maximumUnitCount = 2
        return "Resets in " + (formatter.string(from:date.timeIntervalSinceNow) ?? "soon")
    }
    private func duration(_ seconds:Double)->String {let h = Int(seconds)/3600;return "\(h/24)d \(h%24)h"}
    @MainActor private func exportImage() {
        let content = VStack(alignment:.leading,spacing:20){Text("Activity Agent").font(.largeTitle.bold());overview}.padding(32).frame(width:1200).background(Color(nsColor:.windowBackgroundColor)).environmentObject(model)
        let renderer = ImageRenderer(content:content);renderer.scale = 2
        guard let image = renderer.nsImage,let tiff = image.tiffRepresentation,let bitmap = NSBitmapImageRep(data:tiff),let data = bitmap.representation(using:.png,properties:[:]) else {return}
        let panel = NSSavePanel();panel.allowedContentTypes = [.png];panel.nameFieldStringValue = "Activity Overview.png"
        if panel.runModal() == .OK,let url = panel.url {do {try data.write(to:url)} catch {settingsError = error.localizedDescription}}
    }
}
struct MetricSmall:View {let label:String;let value:String;var body:some View{VStack(alignment:.leading,spacing:8){Text(label).font(.caption).foregroundStyle(.secondary);Text(value).font(.system(size:24,weight:.semibold,design:.rounded)).monospacedDigit()}.frame(maxWidth:.infinity,alignment:.leading).padding(20).cardSurface()}}
struct MetricCard:View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let title:String;let value:String;let detail:String;let symbol:String;let color:Color;let values:[Double]
    var body:some View {
        VStack(alignment:.leading,spacing:14){HStack{Label(title,systemImage:symbol).font(.system(size:12,weight:.medium)).foregroundStyle(.secondary);Spacer();Circle().fill(color).frame(width:5,height:5)};Text(value).font(.system(size:30,weight:.medium,design:.rounded)).monospacedDigit().contentTransition(.opacity).environment(\.contentTransitionAddsDrawingGroup,true).animation(reduceMotion || scenePhase != .active || !NSApp.isActive ? nil : .easeOut(duration:0.18),value:value);Text(detail).font(.caption).foregroundStyle(.secondary)
            if title == "Memory" { DotPlot(values:values,color:color).frame(height:58) }
            else { SoftTrendGraph(values:values,color:color,ceiling:title == "Network" ? max(1,values.max() ?? 1) : 100).frame(height:58) }

        }.padding(20).frame(maxWidth:.infinity,alignment:.leading).cardSurface()
    }
}
extension View {
    @ViewBuilder func navigationGlass()->some View { if #available(macOS 26.0,*) { self.glassEffect(.regular,in:.rect(cornerRadius:20)) } else { self.background(.regularMaterial,in:RoundedRectangle(cornerRadius:20)) } }
    func cardSurface()->some View {self.background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:20)).overlay(RoundedRectangle(cornerRadius:20).strokeBorder(Color.primary.opacity(0.055),lineWidth:0.5))}
    @ViewBuilder func glassPill()->some View {if #available(macOS 26.0,*) {self.glassEffect(.regular,in:.capsule)} else {self.background(.regularMaterial,in:Capsule())}}
}
