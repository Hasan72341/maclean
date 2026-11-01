import MacLeanCore
import SwiftUI

enum PerformanceRoute: Hashable {
    case startupItems
    case userAgents
    case globalAgents
    case launchDaemons
    case brokenItems
    case runningItems
    case loginItems
    case startupItemDetail(String)
    case snapshots
    case memory
    case cpu
    case heavyConsumers
    case topCPU
    case topMemory
    case processDetail(Int32)
    case energy
    case sleepAssertions
    case maintenance
    case maintenanceHistory
    case flushDNS
    case reindexLaunchServices
    case rebuildSpotlight
    case clearFontCaches
    case runPeriodicScripts
    case verifyDisk
    case repairHomePermissions
    case thinSnapshots
    case freeRAM
}

enum PerformanceModule {
    @MainActor @ViewBuilder
    static func root() -> some View {
        PerformanceOverviewScreen()
    }

    @MainActor @ViewBuilder
    static func destination(_ route: PerformanceRoute) -> some View {
        switch route {
        case .startupItems: PerformanceStartupListScreen(filter: .all)
        case .userAgents: PerformanceStartupListScreen(filter: .userAgents)
        case .globalAgents: PerformanceStartupListScreen(filter: .globalAgents)
        case .launchDaemons: PerformanceStartupListScreen(filter: .daemons)
        case .brokenItems: PerformanceStartupListScreen(filter: .broken)
        case .runningItems: PerformanceStartupListScreen(filter: .running)
        case .loginItems: PerformanceLoginItemsScreen()
        case .startupItemDetail(let path): PerformanceStartupDetailScreen(path: path)
        case .snapshots: PerformanceSnapshotsScreen()
        case .memory: PerformanceMemoryScreen()
        case .cpu: PerformanceCPUScreen()
        case .heavyConsumers: PerformanceHeavyConsumersScreen()
        case .topCPU: PerformanceProcessListScreen(byMemory: false)
        case .topMemory: PerformanceProcessListScreen(byMemory: true)
        case .processDetail(let pid): PerformanceProcessDetailScreen(pid: pid)
        case .energy: PerformanceEnergyScreen()
        case .sleepAssertions: PerformanceAssertionsScreen()
        case .maintenance: PerformanceMaintenanceScreen()
        case .maintenanceHistory: PerformanceHistoryScreen()
        case .flushDNS: PerformanceTaskScreen(task: .flushDNS)
        case .reindexLaunchServices: PerformanceTaskScreen(task: .reindexLaunchServices)
        case .rebuildSpotlight: PerformanceTaskScreen(task: .rebuildSpotlight)
        case .clearFontCaches: PerformanceTaskScreen(task: .clearFontCaches)
        case .runPeriodicScripts: PerformanceTaskScreen(task: .runPeriodicScripts)
        case .verifyDisk: PerformanceTaskScreen(task: .verifyDisk)
        case .repairHomePermissions: PerformanceTaskScreen(task: .repairHomePermissions)
        case .thinSnapshots: PerformanceTaskScreen(task: .thinSnapshots)
        case .freeRAM: PerformanceTaskScreen(task: .freeRAM)
        }
    }

    static func title(_ route: PerformanceRoute) -> String {
        switch route {
        case .startupItems: return "Startup Items"
        case .userAgents: return "User Launch Agents"
        case .globalAgents: return "Global Launch Agents"
        case .launchDaemons: return "Launch Daemons"
        case .brokenItems: return "Broken Startup Items"
        case .runningItems: return "Running Startup Items"
        case .loginItems: return "Login Items"
        case .startupItemDetail(let path): return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        case .snapshots: return "Local Snapshots"
        case .memory: return "Memory"
        case .cpu: return "CPU Load"
        case .heavyConsumers: return "Heavy Consumers"
        case .topCPU: return "Top CPU Processes"
        case .topMemory: return "Top Memory Processes"
        case .processDetail(let pid): return "Process \(pid)"
        case .energy: return "Energy"
        case .sleepAssertions: return "Sleep Blockers"
        case .maintenance: return "Maintenance"
        case .maintenanceHistory: return "Maintenance History"
        case .flushDNS: return "Flush DNS Cache"
        case .reindexLaunchServices: return "Rebuild Launch Services"
        case .rebuildSpotlight: return "Reindex Spotlight"
        case .clearFontCaches: return "Clear Font Caches"
        case .runPeriodicScripts: return "Run Maintenance Scripts"
        case .verifyDisk: return "Verify Startup Disk"
        case .repairHomePermissions: return "Repair Home Permissions"
        case .thinSnapshots: return "Thin Local Snapshots"
        case .freeRAM: return "Free Up RAM"
        }
    }
}
