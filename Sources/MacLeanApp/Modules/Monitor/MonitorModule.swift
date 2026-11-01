import MacLeanCore
import SwiftUI

enum MonitorRoute: Hashable {
    case healthScore
    case cpuOverview
    case cores
    case coreDetail(Int)
    case loadAverage
    case topCPU
    case memoryOverview
    case memoryPressure
    case topMemory
    case processList
    case processDetail(Int)
    case processUsers
    case userProcesses(String)
    case diskOverview
    case diskIO
    case volumes
    case volumeDetail(String)
    case networkOverview
    case interfaceDetail(String)
    case battery
    case thermal
    case powerAssertions
    case systemInfo
    case activityLog
    case samplingSettings
}

enum MonitorModule {
    @MainActor @ViewBuilder
    static func root() -> some View {
        MonitorDashboardScreen()
    }

    @MainActor @ViewBuilder
    static func destination(_ route: MonitorRoute) -> some View {
        switch route {
        case .healthScore: MonitorHealthScreen()
        case .cpuOverview: MonitorCPUScreen()
        case .cores: MonitorCoresScreen()
        case .coreDetail(let index): MonitorCoreDetailScreen(index: index)
        case .loadAverage: MonitorLoadScreen()
        case .topCPU: MonitorTopProcessesScreen(mode: .cpu)
        case .memoryOverview: MonitorMemoryScreen()
        case .memoryPressure: MonitorPressureScreen()
        case .topMemory: MonitorTopProcessesScreen(mode: .memory)
        case .processList: MonitorProcessListScreen(userFilter: nil)
        case .processDetail(let pid): MonitorProcessDetailScreen(pid: Int32(truncatingIfNeeded: pid))
        case .processUsers: MonitorProcessUsersScreen()
        case .userProcesses(let user): MonitorProcessListScreen(userFilter: user)
        case .diskOverview: MonitorDiskScreen()
        case .diskIO: MonitorDiskIOScreen()
        case .volumes: MonitorVolumesScreen()
        case .volumeDetail(let path): MonitorVolumeDetailScreen(path: path)
        case .networkOverview: MonitorNetworkScreen()
        case .interfaceDetail(let name): MonitorInterfaceScreen(name: name)
        case .battery: MonitorBatteryScreen()
        case .thermal: MonitorThermalScreen()
        case .powerAssertions: MonitorAssertionsScreen()
        case .systemInfo: MonitorSystemInfoScreen()
        case .activityLog: MonitorActivityScreen()
        case .samplingSettings: MonitorSamplingScreen()
        }
    }

    static func title(_ route: MonitorRoute) -> String {
        switch route {
        case .healthScore: return "Health Score"
        case .cpuOverview: return "CPU"
        case .cores: return "CPU Cores"
        case .coreDetail(let index): return "Core \(index)"
        case .loadAverage: return "Load Average"
        case .topCPU: return "Top CPU"
        case .memoryOverview: return "Memory"
        case .memoryPressure: return "Memory Pressure"
        case .topMemory: return "Top Memory"
        case .processList: return "Processes"
        case .processDetail(let pid): return "Process \(pid)"
        case .processUsers: return "Processes by User"
        case .userProcesses(let user): return "User \(user)"
        case .diskOverview: return "Disk"
        case .diskIO: return "Disk Activity"
        case .volumes: return "Volumes"
        case .volumeDetail(let path): return path == "/" ? "Startup Disk" : (path as NSString).lastPathComponent
        case .networkOverview: return "Network"
        case .interfaceDetail(let name): return name
        case .battery: return "Battery"
        case .thermal: return "Thermal & Uptime"
        case .powerAssertions: return "Sleep Blockers"
        case .systemInfo: return "System Info"
        case .activityLog: return "Activity"
        case .samplingSettings: return "Sampling"
        }
    }
}

// MARK: - Shared helpers

enum MonitorFmt {
    static func cpu(_ fraction: Double) -> String { String(format: "%.0f%%", fraction * 100) }
    static func cpu1(_ fraction: Double) -> String { String(format: "%.1f%%", fraction * 100) }
    static func psCPU(_ value: Double) -> String { String(format: "%.1f%%", value) }
    static func load(_ value: Double) -> String { String(format: "%.2f", value) }
    static func bytes(_ value: Double) -> String { Format.bytes(Int64(max(0, value))) }
    static func average(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }

    static func tint(forFraction value: Double) -> Color {
        if value >= 0.85 { return Theme.danger }
        if value >= 0.6 { return Theme.warning }
        return Theme.success
    }

    static func healthTint(_ score: Int) -> Color {
        if score >= 80 { return Theme.success }
        if score >= 55 { return Theme.warning }
        return Theme.danger
    }

    static func thermalTint(_ state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal: return Theme.success
        case .fair: return Theme.info
        case .serious: return Theme.warning
        case .critical: return Theme.danger
        @unknown default: return Theme.muted
        }
    }
}

/// Wraps a tile (or any view) as a button pushing a Monitor route.
struct MonitorLink<Content: View>: View {
    let route: MonitorRoute
    @ViewBuilder var content: () -> Content
    @EnvironmentObject private var nav: Navigator
    @State private var hovering = false

    var body: some View {
        Button { nav.push(.monitor(route)) } label: {
            content()
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(hovering ? Theme.accent : Theme.faint)
                        .padding(10)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MonitorStatsLine: View {
    let values: [Double]
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 18) {
            stat("NOW", values.last ?? 0)
            stat("AVG", MonitorFmt.average(values))
            stat("MIN", values.min() ?? 0)
            stat("PEAK", values.max() ?? 0)
            Spacer()
            Text("\(values.count) samples").font(Type.mono(9)).foregroundStyle(Theme.faint)
        }
    }

    private func stat(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 5) {
            Text(label).font(Type.mono(9, weight: .semibold)).foregroundStyle(Theme.faint)
            Text(format(value)).font(Type.mono(11, weight: .semibold)).foregroundStyle(Theme.ink).monospacedDigit()
        }
    }
}

struct MonitorCommandCard: View {
    let output: MonitorCommandOutput

    var body: some View {
        Card(output.title, trailing: output.status == 0 ? "exit 0" : "exit \(output.status)") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(output.command).font(Type.mono(10)).foregroundStyle(Theme.muted).textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output.command, forType: .string)
                    }
                    .buttonStyle(EditorialButtonStyle(kind: .inline))
                }
                ScrollView(.horizontal) {
                    Text(output.output.isEmpty ? "(no output)" : output.output)
                        .font(Type.mono(10))
                        .foregroundStyle(output.status == 0 ? Theme.ink : Theme.danger)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(Format.date(output.date)).font(Type.mono(9)).foregroundStyle(Theme.faint)
            }
        }
    }
}

struct MonitorCopyCommand: View {
    let command: String

    var body: some View {
        HStack {
            Text(command).font(Type.mono(11)).foregroundStyle(Theme.ink).textSelection(.enabled)
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                ToastCenter.shared.show("Copied: \(command)")
            }
            .buttonStyle(EditorialButtonStyle(kind: .inline))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
    }
}

struct MonitorPauseButton: View {
    @ObservedObject private var store = MonitorStore.shared

    var body: some View {
        Button(store.paused ? "Resume" : "Pause") { store.setPaused(!store.paused) }
            .buttonStyle(EditorialButtonStyle(kind: .secondary))
            .help(store.paused ? "Resume live sampling" : "Pause live sampling")
    }
}
