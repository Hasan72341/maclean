import MacLeanCore
import SwiftUI

struct PerformanceOverviewScreen: View {
    @ObservedObject private var store = PerformanceStore.shared
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let m = monitor.latest.memory
        ScreenScaffold("Performance", subtitle: "Startup items, memory, snapshots and maintenance — all live from this Mac") {
            Button("Rescan") { rescan() }
                .buttonStyle(EditorialButtonStyle(kind: .secondary))
                .disabled(store.startupState.isLoading || store.snapshotState.isLoading)
        } content: {
            TileGrid {
                PerformanceTapTile(route: .startupItems) {
                    StatTile(label: "Startup items", value: store.startupState.loadedAt == nil ? "…" : Format.count(store.startupItems.count),
                             detail: "\(Format.count(store.items(.running).count)) running now", icon: "power")
                }
                PerformanceTapTile(route: .brokenItems) {
                    StatTile(label: "Broken", value: store.startupState.loadedAt == nil ? "…" : Format.count(store.items(.broken).count),
                             detail: "missing programs", tint: store.items(.broken).isEmpty ? Theme.success : Theme.warning, icon: "exclamationmark.triangle")
                }
                PerformanceTapTile(route: .snapshots) {
                    StatTile(label: "Local snapshots", value: store.snapshotState.loadedAt == nil ? "…" : Format.count(store.snapshots.count),
                             detail: store.snapshots.first.flatMap(\.date).map { "newest \(Format.relative($0))" } ?? "Time Machine", icon: "clock.arrow.circlepath")
                }
                PerformanceTapTile(route: .memory) {
                    StatTile(label: "Memory used", value: Format.percent(m.usedFraction), detail: "\(Format.bytes(m.used)) of \(Format.bytes(m.total)) · \(m.pressureTitle)",
                             tint: PerformanceColors.pressure(m.pressureLevel), history: monitor.memoryHistory, icon: "memorychip")
                }
                PerformanceTapTile(route: .cpu) {
                    StatTile(label: "CPU", value: Format.percent(monitor.latest.cpu.total), detail: String(format: "load %.2f", monitor.latest.loadAverage.first ?? 0),
                             history: monitor.cpuHistory, icon: "cpu")
                }
                PerformanceTapTile(route: .energy) {
                    StatTile(label: "Thermal", value: monitor.latest.thermalTitle,
                             detail: monitor.latest.battery.map { "battery \($0.percent)%\($0.isCharging ? " · charging" : "")" } ?? "AC power",
                             tint: monitor.latest.thermalState == .nominal ? Theme.success : Theme.warning, icon: "thermometer.medium")
                }
            }

            HStack(alignment: .top, spacing: 16) {
                Card("Memory · live", trailing: "pressure \(m.pressureTitle.lowercased())") {
                    LiveChart(series: [
                        .init(values: monitor.memoryBytesHistory, color: Theme.accent, label: "Used"),
                        .init(values: monitor.compressedHistory, color: Theme.info, label: "Compressed"),
                        .init(values: monitor.swapHistory, color: Theme.warning, label: "Swap", fill: false),
                    ], maxValue: Double(m.total), format: { Format.bytes(Int64($0)) }, height: 130)
                    StackedBar(segments: PerformanceColors.memorySegments(m), total: Double(m.total))
                }
                Card("CPU · live", trailing: "\(monitor.latest.cpu.cores.count) cores") {
                    LiveChart(series: [
                        .init(values: monitor.cpuUserHistory.map { $0 * 100 }, color: Theme.accent, label: "User"),
                        .init(values: monitor.cpuSystemHistory.map { $0 * 100 }, color: Theme.info, label: "System"),
                    ], maxValue: 100, format: { String(format: "%.0f%%", $0) }, height: 130)
                    HStack {
                        Text("\(Format.count(monitor.latest.processCount)) processes").font(Type.text(11)).foregroundStyle(Theme.muted)
                        Spacer()
                        Text("up \(Format.duration(monitor.latest.uptime))").font(Type.mono(10)).foregroundStyle(Theme.faint)
                    }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                Card("Startup items by kind", trailing: store.startupState.loadedAt.map { "scanned \(Format.relative($0))" }) {
                    if store.startupState.isLoading && store.startupItems.isEmpty {
                        LoadingPanel(text: "Reading launchd jobs…")
                    } else {
                        let total = Double(max(1, store.startupItems.count))
                        ForEach([PerformanceStartupFilter.userAgents, .globalAgents, .daemons, .running, .broken], id: \.self) { filter in
                            BarRow(label: filter.title, value: Double(store.items(filter).count), total: total,
                                   valueText: Format.count(store.items(filter).count),
                                   tint: filter == .broken ? Theme.warning : Theme.accent) {
                                nav.push(.performance(PerformanceStartupFilter.route(filter)))
                            }
                        }
                    }
                }
                Card("Heavy consumers · live", trailing: "\(Format.count(monitor.processes.count)) procs") {
                    let top = Array(monitor.processes.sorted { $0.cpu > $1.cpu }.prefix(5))
                    if top.isEmpty {
                        Text("Sampling processes…").font(Type.text(12)).foregroundStyle(Theme.muted)
                    }
                    ForEach(top) { proc in
                        BarRow(label: proc.name, value: proc.cpu, total: max(100, top.first?.cpu ?? 100),
                               valueText: String(format: "%.1f%% · %@", proc.cpu, Format.bytes(proc.memory))) {
                            nav.push(.performance(.processDetail(proc.pid)))
                        }
                    }
                    Button("All heavy consumers") { nav.push(.performance(.heavyConsumers)) }
                        .buttonStyle(EditorialButtonStyle(kind: .inline))
                }
            }

            SectionHeader(title: "Maintenance", detail: "\(PerformanceTask.allCases.count) tasks")
            PerformanceTaskGrid()

            SectionHeader(title: "Explore")
            VStack(spacing: 8) {
                NavRow(icon: "power", title: "Startup Items", subtitle: "All launch agents and daemons, grouped by location",
                       value: Format.count(store.startupItems.count), route: .performance(.startupItems))
                NavRow(icon: "person.crop.square", title: "Login Items", subtitle: "Apps that open when you log in (System Events)",
                       value: store.loginState.loadedAt == nil ? nil : Format.count(store.loginItems.count), route: .performance(.loginItems))
                NavRow(icon: "clock.arrow.circlepath", title: "Local Snapshots", subtitle: "Time Machine snapshots holding purgeable space",
                       value: Format.count(store.snapshots.count), route: .performance(.snapshots))
                NavRow(icon: "memorychip", title: "Memory", subtitle: "Live composition, pressure, Free up RAM",
                       value: Format.bytes(m.used), route: .performance(.memory))
                NavRow(icon: "cpu", title: "CPU Load", subtitle: "Per-core live load and load averages",
                       value: Format.percent(monitor.latest.cpu.total), route: .performance(.cpu))
                NavRow(icon: "flame", title: "Heavy Consumers", subtitle: "Top CPU and memory processes",
                       route: .performance(.heavyConsumers))
                NavRow(icon: "bolt.batteryblock", title: "Energy", subtitle: "Battery, thermal state and sleep blockers",
                       value: monitor.latest.battery.map { "\($0.percent)%" }, route: .performance(.energy))
                NavRow(icon: "wrench.and.screwdriver", title: "Maintenance", subtitle: "Run macOS maintenance tasks with full output",
                       value: "\(PerformanceTask.allCases.count)", route: .performance(.maintenance))
                NavRow(icon: "list.bullet.rectangle", title: "Maintenance History", subtitle: "Every task run with exit status and output",
                       value: Format.count(store.history.count), route: .performance(.maintenanceHistory))
            }
        }
        .onAppear {
            store.loadStartupIfNeeded()
            store.loadSnapshotsIfNeeded()
        }
    }

    private func rescan() {
        Task {
            await store.loadStartup()
            await store.loadSnapshots()
            await store.loadMemory()
        }
    }
}

extension PerformanceStartupFilter {
    static func route(_ filter: PerformanceStartupFilter) -> PerformanceRoute {
        switch filter {
        case .all: return .startupItems
        case .userAgents: return .userAgents
        case .globalAgents: return .globalAgents
        case .daemons: return .launchDaemons
        case .broken: return .brokenItems
        case .running: return .runningItems
        }
    }
}

/// Makes any tile push a route when clicked.
struct PerformanceTapTile<Content: View>: View {
    let route: PerformanceRoute
    @ViewBuilder var content: () -> Content
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        Button { nav.push(.performance(route)) } label: { content() }
            .buttonStyle(.plain)
    }
}

enum PerformanceColors {
    static func pressure(_ level: Int) -> Color {
        switch level {
        case 4: return Theme.danger
        case 2: return Theme.warning
        default: return Theme.success
        }
    }

    static func load(_ fraction: Double) -> Color {
        fraction > 0.85 ? Theme.danger : fraction > 0.6 ? Theme.warning : Theme.accent
    }

    static func memorySegments(_ m: MemorySample) -> [StackedBar.Segment] {
        [
            .init(label: "App", value: Double(m.appMemory), color: Theme.accent, text: Format.bytes(m.appMemory)),
            .init(label: "Wired", value: Double(m.wired), color: Theme.danger, text: Format.bytes(m.wired)),
            .init(label: "Compressed", value: Double(m.compressed), color: Theme.info, text: Format.bytes(m.compressed)),
            .init(label: "Cached", value: Double(m.cached), color: Theme.warning, text: Format.bytes(m.cached)),
            .init(label: "Free", value: Double(m.free), color: Theme.success, text: Format.bytes(m.free)),
        ]
    }
}
