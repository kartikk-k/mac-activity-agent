import SwiftUI
import AppKit
import ActivityCore

@main struct ActivityAgentApp: App {
    @StateObject private var model = MonitorModel()
    var body: some Scene {
        Window("Activity Agent", id: "main") {
            DashboardView().environmentObject(model).frame(minWidth: 1000, minHeight: 680)
        }.defaultSize(width: 1220, height: 820).windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { model.refresh(force: true) }.keyboardShortcut("r")
                Button(model.paused ? "Resume monitoring" : "Pause monitoring") { model.paused.toggle() }.keyboardShortcut("p", modifiers: [.command,.shift])
            }
        }
        MenuBarExtra {
            MenuPanel().environmentObject(model)
        } label: {
            Label(menuTitle, systemImage: "waveform.path.ecg")
        }.menuBarExtraStyle(.window)
    }
    private var menuTitle: String {
        guard let system = model.system else { return "—" }
        switch model.menuMetric {
        case "Memory": return bytes(system.memoryUsed)
        case "Network": return bytes(system.networkReceivedBytes) + "/s"
        default: return String(format: "%.0f%%", system.cpuPercent)
        }
    }
}
struct MenuPanel: View {
    @EnvironmentObject var model: MonitorModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Label("Activity Agent", systemImage: "waveform.path.ecg").font(.headline); Spacer(); Circle().fill(model.paused ? .orange : .green).frame(width: 6,height: 6) }
            if let s = model.system {
                HStack { menuValue("CPU",String(format:"%.0f%%",s.cpuPercent)); Spacer(); menuValue("Memory",bytes(s.memoryUsed)); Spacer(); menuValue("Download",bytes(s.networkReceivedBytes)+"/s") }
            }
            Divider()
            Text("BUSIEST APPLICATIONS").font(.system(size: 10,weight: .semibold)).foregroundStyle(.secondary)
            ForEach(model.groups.filter { $0.bundlePath != nil }.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5)) { group in
                Button { model.selectedGroup = group.id; model.section = .apps; openWindow(id:"main"); NSApp.activate(ignoringOtherApps:true) } label: {
                    HStack { Image(nsImage:model.icon(group)).resizable().frame(width:22,height:22); Text(group.name).lineLimit(1); Spacer(); Text(model.cpu(group.cpuPercent)).monospacedDigit().foregroundStyle(.secondary) }
                }.buttonStyle(.plain)
            }
            Divider()
            HStack { Button("Open monitor") { openWindow(id:"main"); NSApp.activate(ignoringOtherApps:true) }; Spacer(); Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary) }
        }.padding(20).frame(width:340)
    }
    func menuValue(_ title:String,_ value:String) -> some View { VStack(alignment:.leading,spacing:4) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(.body,design:.rounded,weight:.semibold)).monospacedDigit() } }
}
