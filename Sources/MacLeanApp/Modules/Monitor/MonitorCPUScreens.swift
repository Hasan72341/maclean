import MacLeanCore
import SwiftUI

// MARK: - Health

struct MonitorHealthScreen: View {
    @ObservedObject private var monitor = SystemMonitor.shared

    private struct Factor: Identifiable {
        var id: String { title }
        let title: String
        let detail: String
        let penalty: Double
        let route: MonitorRoute
    }

    private func factors(_ s: MetricsSnapshot) -> [Factor] {
        [
            Factor(title: "CPU load", detail: "\(MonitorFmt.cpu(s.cpu.total)) busy (penalty above 50%)", penalty: max(0, s.cpu.total - 0.5) * 40, route: .cpuOverview),
            Factor(title: "Memory use", detail: "\(MonitorFmt.cpu(s.memory.usedFraction)) used (penalty above 70%)", penalty: max(0, s.memory.usedFraction - 0.7) * 60, route: .memoryOverview),
            Factor(title: "Disk use", detail: "\(MonitorFmt.cpu(s.disk.usedFraction)) full (penalty above 80%)", penalty: max(0, s.disk.usedFraction - 0.8) * 120, route: .diskOverview),
            Factor(title: "Memory pressure", detail: s.memory.pressureTitle, penalty: (s.memory.pressureLevel >= 2 ? 10 : 0) + (s.memory.pressureLevel >= 4 ? 15 : 0), route: .memoryPressure),
            Factor(title: "Thermal state", detail: s.thermalTitle, penalty: s.thermalState == .serious ? 10 : (s.thermalState == .critical ? 20 : 0), route: .thermal),
        ]
    }

    var body: some View {
        let s = monitor.latest
        let list = factors(s)
        ScreenScaffold("Health Score", subtitle: "How the 0–100 score is computed from live readings") {
            TileGrid {
                StatTile(label: "Score", value: "\(s.healthScore)", unit: "/ 100", tint: MonitorFmt.healthTint(s.healthScore), history: monitor.healthHistory, icon: "heart.text.square")
                StatTile(label: "Average", value: String(format: "%.0f", MonitorFmt.average(monitor.healthHistory)), detail: "over \(monitor.healthHistory.count) samples")
                StatTile(label: "Lowest", value: String(format: "%.0f", monitor.healthHistory.min() ?? 0), tint: Theme.warning)
                StatTile(label: "Total penalty", value: String(format: "%.1f", list.reduce(0) { $0 + $1.penalty }), tint: Theme.danger)
            }
            Card("Score history") {
                LiveChart(series: [.init(values: monitor.healthHistory, color: MonitorFmt.healthTint(s.healthScore), label: "Health")], maxValue: 100, height: 160)
            }
            Card("Factors") {
                VStack(spacing: 10) {
                    ForEach(list) { factor in
                        MonitorLink(route: factor.route) {
                            VStack(alignment: .leading, spacing: 4) {
                                BarRow(label: factor.title, value: factor.penalty, total: 30, valueText: String(format: "−%.1f", factor.penalty), tint: factor.penalty > 0 ? Theme.danger : Theme.success)
                                Text(factor.detail).font(Type.text(11)).foregroundStyle(Theme.muted)
                            }
                            .padding(.trailing, 24)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - CPU overview

struct MonitorCPUScreen: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var store = MonitorStore.shared

    var body: some View {
        let s = monitor.latest
        ScreenScaffold("CPU", subtitle: "\(s.cpu.cores.count) logical cores · live", actions: { MonitorPauseButton() }) {
            TileGrid {
                StatTile(label: "Total", value: MonitorFmt.cpu1(s.cpu.total), tint: Theme.accent, history: monitor.cpuHistory, icon: "cpu")
                StatTile(label: "User", value: MonitorFmt.cpu1(s.cpu.user), tint: Theme.info, history: monitor.cpuUserHistory)
                StatTile(label: "System", value: MonitorFmt.cpu1(s.cpu.system), tint: Theme.warning, history: monitor.cpuSystemHistory)
                StatTile(label: "Idle", value: MonitorFmt.cpu1(s.cpu.idle), tint: Theme.success)
                StatTile(label: "Load 1m", value: MonitorFmt.load(s.loadAverage.first ?? 0), detail: "per core \(MonitorFmt.load((s.loadAverage.first ?? 0) / Double(max(1, s.cpu.cores.count))))", history: monitor.loadHistory)
                StatTile(label: "Session peak", value: MonitorFmt.cpu(store.peakCPU), tint: Theme.danger)
            }
            Card("User vs system · live") {
                VStack(alignment: .leading, spacing: 8) {
                    LiveChart(
                        series: [
                            .init(values: monitor.cpuUserHistory, color: Theme.info, label: "User"),
                            .init(values: monitor.cpuSystemHistory, color: Theme.warning, label: "System"),
                            .init(values: monitor.cpuHistory, color: Theme.accent, label: "Total", fill: false),
                        ],
                        maxValue: 1, format: { MonitorFmt.cpu($0) }, height: 180
                    )
                    MonitorStatsLine(values: monitor.cpuHistory, format: { MonitorFmt.cpu1($0) })
                }
            }
            Card("Breakdown") {
                StackedBar(segments: [
                    .init(label: "User", value: s.cpu.user, color: Theme.info, text: MonitorFmt.cpu1(s.cpu.user)),
                    .init(label: "System", value: s.cpu.system, color: Theme.warning, text: MonitorFmt.cpu1(s.cpu.system)),
                    .init(label: "Idle", value: s.cpu.idle, color: Theme.line, text: MonitorFmt.cpu1(s.cpu.idle)),
                ], total: 1)
            }
            Card("Top consumers", trailing: "from ps, every 3 samples") {
                VStack(spacing: 8) {
                    let top = monitor.processes.sorted { $0.cpu > $1.cpu }.prefix(5)
                    let peak = max(100, top.first?.cpu ?? 100)
                    ForEach(Array(top)) { process in
                        MonitorLink(route: .processDetail(Int(process.pid))) {
                            BarRow(label: "\(process.name)  ·  \(process.pid)", value: process.cpu, total: peak, valueText: MonitorFmt.psCPU(process.cpu))
                                .padding(.trailing, 24)
                        }
                    }
                }
            }
            VStack(spacing: 8) {
                NavRow(icon: "square.grid.3x3", title: "Per-core load", subtitle: "\(s.cpu.cores.count) cores", value: MonitorFmt.cpu(MonitorFmt.average(s.cpu.cores)), route: .monitor(.cores))
                NavRow(icon: "chart.line.uptrend.xyaxis", title: "Load average", subtitle: "1 / 5 / 15 minute run queue", value: s.loadAverage.map { MonitorFmt.load($0) }.joined(separator: " "), route: .monitor(.loadAverage))
                NavRow(icon: "flame", title: "Top CPU processes", subtitle: "quit or inspect", value: Format.count(monitor.processes.count), route: .monitor(.topCPU))
                NavRow(icon: "thermometer.medium", title: "Thermal state", value: s.thermalTitle, tint: MonitorFmt.thermalTint(s.thermalState), route: .monitor(.thermal))
            }
        }
    }
}

// MARK: - Cores

struct MonitorCoresScreen: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var store = MonitorStore.shared

    var body: some View {
        let cores = monitor.latest.cpu.cores
        let info = store.systemInfo
        ScreenScaffold("CPU Cores", subtitle: "\(cores.count) logical cores · tap a core for its history") {
            TileGrid {
                StatTile(label: "Cores", value: "\(cores.count)", detail: info.map { "\($0.physicalCores) physical" } ?? nil, icon: "square.grid.3x3")
                StatTile(label: "Average", value: MonitorFmt.cpu(MonitorFmt.average(cores)), tint: Theme.accent)
                StatTile(label: "Busiest", value: MonitorFmt.cpu(cores.max() ?? 0), detail: cores.firstIndex(of: cores.max() ?? 0).map { "core \($0)" }, tint: Theme.danger)
                StatTile(label: "Above 50%", value: "\(cores.filter { $0 > 0.5 }.count)", tint: Theme.warning)
                if let p = info?.performanceCores, let e = info?.efficiencyCores {
                    StatTile(label: "P / E cores", value: "\(p) / \(e)", detail: "performance / efficiency")
                }
            }
            if cores.isEmpty {
                LoadingPanel(text: "Waiting for the first per-core sample…")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(cores.indices, id: \.self) { index in
                        MonitorLink(route: .coreDetail(index)) {
                            StatTile(
                                label: "Core \(index)",
                                value: MonitorFmt.cpu(cores[index]),
                                tint: MonitorFmt.tint(forFraction: cores[index]),
                                history: index < monitor.coreHistory.count ? monitor.coreHistory[index] : nil
                            )
                        }
                    }
                }
            }
        }
        .task { await store.loadSystemInfo() }
    }
}

struct MonitorCoreDetailScreen: View {
    let index: Int
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        let cores = monitor.latest.cpu.cores
        let history = index < monitor.coreHistory.count ? monitor.coreHistory[index] : []
        ScreenScaffold("Core \(index)", subtitle: "Live utilisation of logical core \(index)") {
            if index >= cores.count {
                EmptyPanel(icon: "cpu", title: "Core \(index) is not reported", message: "This Mac reports \(cores.count) logical cores.")
            } else {
                TileGrid {
                    StatTile(label: "Now", value: MonitorFmt.cpu1(cores[index]), tint: MonitorFmt.tint(forFraction: cores[index]), icon: "cpu")
                    StatTile(label: "Average", value: MonitorFmt.cpu1(MonitorFmt.average(history)))
                    StatTile(label: "Peak", value: MonitorFmt.cpu1(history.max() ?? 0), tint: Theme.danger)
                    StatTile(label: "vs all cores", value: String(format: "%+.0f pts", (cores[index] - MonitorFmt.average(cores)) * 100), detail: "against \(MonitorFmt.cpu(MonitorFmt.average(cores))) mean")
                }
                Card("Core \(index) · live") {
                    VStack(alignment: .leading, spacing: 8) {
                        LiveChart(series: [
                            .init(values: history, color: Theme.accent, label: "Core \(index)"),
                            .init(values: monitor.cpuHistory, color: Theme.info, label: "All cores", fill: false),
                        ], maxValue: 1, format: { MonitorFmt.cpu($0) }, height: 200)
                        MonitorStatsLine(values: history, format: { MonitorFmt.cpu1($0) })
                    }
                }
                HStack(spacing: 10) {
                    if index > 0 {
                        NavRow(icon: "chevron.left", title: "Core \(index - 1)", value: MonitorFmt.cpu(cores[index - 1]), route: .monitor(.coreDetail(index - 1)))
                    }
                    if index + 1 < cores.count {
                        NavRow(icon: "chevron.right", title: "Core \(index + 1)", value: MonitorFmt.cpu(cores[index + 1]), route: .monitor(.coreDetail(index + 1)))
                    }
                }
            }
        }
    }
}

// MARK: - Load average

struct MonitorLoadScreen: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var store = MonitorStore.shared

    var body: some View {
        let s = monitor.latest
        let cores = Double(max(1, s.cpu.cores.count))
        let one = s.loadAverage.first ?? 0
        ScreenScaffold("Load Average", subtitle: "Average runnable threads over 1, 5 and 15 minutes") {
            TileGrid {
                StatTile(label: "1 minute", value: MonitorFmt.load(one), tint: one > cores ? Theme.danger : Theme.accent, history: monitor.loadHistory)
                StatTile(label: "5 minutes", value: MonitorFmt.load(s.loadAverage.count > 1 ? s.loadAverage[1] : 0), history: store.load5History)
                StatTile(label: "15 minutes", value: MonitorFmt.load(s.loadAverage.count > 2 ? s.loadAverage[2] : 0), history: store.load15History)
                StatTile(label: "Per core", value: MonitorFmt.load(one / cores), detail: "\(Int(cores)) cores · >1.0 means queueing", tint: one / cores > 1 ? Theme.danger : Theme.success)
            }
            Card("Load · live") {
                VStack(alignment: .leading, spacing: 8) {
                    LiveChart(series: [
                        .init(values: monitor.loadHistory, color: Theme.accent, label: "1m"),
                        .init(values: store.load5History, color: Theme.info, label: "5m", fill: false),
                        .init(values: store.load15History, color: Theme.warning, label: "15m", fill: false),
                    ], format: { MonitorFmt.load($0) }, height: 180)
                    MonitorStatsLine(values: monitor.loadHistory, format: { MonitorFmt.load($0) })
                }
            }
            Card("Saturation") {
                VStack(spacing: 10) {
                    BarRow(label: "1 minute vs capacity", value: one, total: cores, valueText: "\(MonitorFmt.load(one)) / \(Int(cores))", tint: MonitorFmt.tint(forFraction: one / cores))
                    BarRow(label: "5 minutes vs capacity", value: s.loadAverage.count > 1 ? s.loadAverage[1] : 0, total: cores, valueText: MonitorFmt.load(s.loadAverage.count > 1 ? s.loadAverage[1] : 0))
                    BarRow(label: "15 minutes vs capacity", value: s.loadAverage.count > 2 ? s.loadAverage[2] : 0, total: cores, valueText: MonitorFmt.load(s.loadAverage.count > 2 ? s.loadAverage[2] : 0))
                }
            }
            NavRow(icon: "flame", title: "What is using the CPU?", subtitle: "Top processes by CPU", route: .monitor(.topCPU))
        }
    }
}
