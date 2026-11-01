import MacLeanCore
import SwiftUI

struct MonitorDashboardScreen: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var store = MonitorStore.shared
    @ObservedObject private var log = ActivityLog.shared

    var body: some View {
        let s = monitor.latest
        ScreenScaffold(
            "Dashboard",
            subtitle: store.paused ? "Live sampling paused" : "Live system health · sampling every \(String(format: "%g", monitor.intervalSeconds))s",
            actions: { MonitorPauseButton() }
        ) {
            healthCard(s)
            tiles(s)
            Card("CPU & memory · live", trailing: "last \(monitor.cpuHistory.count) samples") {
                LiveChart(
                    series: [
                        .init(values: monitor.cpuHistory, color: Theme.accent, label: "CPU"),
                        .init(values: monitor.memoryHistory, color: Theme.info, label: "Memory", fill: false),
                    ],
                    maxValue: 1,
                    format: { MonitorFmt.cpu($0) },
                    height: 150
                )
            }
            HStack(alignment: .top, spacing: 16) {
                Card("Network · live") {
                    LiveChart(
                        series: [
                            .init(values: monitor.netRxHistory, color: Theme.success, label: "Down"),
                            .init(values: monitor.netTxHistory, color: Theme.accent, label: "Up", fill: false),
                        ],
                        format: { Format.rate($0) },
                        height: 90
                    )
                }
                Card("Disk I/O · live") {
                    LiveChart(
                        series: [
                            .init(values: monitor.diskReadHistory, color: Theme.info, label: "Read"),
                            .init(values: monitor.diskWriteHistory, color: Theme.warning, label: "Write", fill: false),
                        ],
                        format: { Format.rate($0) },
                        height: 90
                    )
                }
            }
            quickActions
            explore(s)
            recentActivity
        }
    }

    private func healthCard(_ s: MetricsSnapshot) -> some View {
        MonitorLink(route: .healthScore) {
            Card("System health", trailing: "\(s.memory.pressureTitle) pressure · \(s.thermalTitle) thermal") {
                HStack(alignment: .center, spacing: 22) {
                    RingGauge(
                        value: Double(s.healthScore) / 100,
                        label: "\(s.healthScore)",
                        caption: "health",
                        tint: MonitorFmt.healthTint(s.healthScore),
                        size: 128,
                        lineWidth: 11
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        LiveChart(
                            series: [.init(values: monitor.healthHistory, color: MonitorFmt.healthTint(s.healthScore), label: "Score")],
                            maxValue: 100,
                            format: { String(format: "%.0f", $0) },
                            height: 92
                        )
                        HStack(spacing: 16) {
                            KeyValueRow(key: "Uptime", value: Format.duration(s.uptime))
                            KeyValueRow(key: "Processes", value: Format.count(s.processCount))
                            KeyValueRow(key: "Load (1m)", value: MonitorFmt.load(s.loadAverage.first ?? 0))
                        }
                    }
                }
            }
        }
    }

    private func tiles(_ s: MetricsSnapshot) -> some View {
        TileGrid(minWidth: 180) {
            MonitorLink(route: .cpuOverview) {
                StatTile(label: "CPU", value: MonitorFmt.cpu(s.cpu.total),
                         detail: "user \(MonitorFmt.cpu(s.cpu.user)) · sys \(MonitorFmt.cpu(s.cpu.system))",
                         tint: Theme.accent, history: monitor.cpuHistory, icon: "cpu")
            }
            MonitorLink(route: .memoryOverview) {
                StatTile(label: "Memory", value: Format.bytes(s.memory.used),
                         detail: "of \(Format.bytes(s.memory.total)) · \(MonitorFmt.cpu(s.memory.usedFraction))",
                         tint: Theme.info, history: monitor.memoryHistory, icon: "memorychip")
            }
            MonitorLink(route: .diskOverview) {
                StatTile(label: "Disk free", value: Format.bytes(s.disk.available),
                         detail: "\(MonitorFmt.cpu(s.disk.usedFraction)) used of \(Format.bytes(s.disk.total))",
                         tint: MonitorFmt.tint(forFraction: s.disk.usedFraction), icon: "internaldrive")
            }
            MonitorLink(route: .networkOverview) {
                StatTile(label: "Net down", value: Format.rate(s.network.rxPerSec),
                         detail: "total \(Format.bytes(s.network.rxTotal))",
                         tint: Theme.success, history: monitor.netRxHistory, icon: "arrow.down.circle")
            }
            MonitorLink(route: .networkOverview) {
                StatTile(label: "Net up", value: Format.rate(s.network.txPerSec),
                         detail: "total \(Format.bytes(s.network.txTotal))",
                         tint: Theme.accent, history: monitor.netTxHistory, icon: "arrow.up.circle")
            }
            MonitorLink(route: .diskIO) {
                StatTile(label: "Disk I/O", value: Format.rate(s.disk.readPerSec + s.disk.writePerSec),
                         detail: "R \(Format.rate(s.disk.readPerSec)) · W \(Format.rate(s.disk.writePerSec))",
                         tint: Theme.warning,
                         history: zip(monitor.diskReadHistory, monitor.diskWriteHistory).map { $0 + $1 },
                         icon: "arrow.left.arrow.right")
            }
            MonitorLink(route: .battery) {
                if let battery = s.battery {
                    StatTile(label: "Battery", value: "\(battery.percent)%",
                             detail: battery.isCharging ? "charging" : (battery.onAC ? "on AC power" : battery.minutesRemaining.map { "\(Format.duration(Double($0) * 60)) left" } ?? "on battery"),
                             tint: battery.percent < 20 ? Theme.danger : Theme.success,
                             history: store.batteryHistory, icon: battery.isCharging ? "battery.100.bolt" : "battery.75")
                } else {
                    StatTile(label: "Power", value: "AC", detail: "no internal battery", icon: "powerplug")
                }
            }
            MonitorLink(route: .thermal) {
                StatTile(label: "Uptime", value: Format.duration(s.uptime),
                         detail: "thermal \(s.thermalTitle.lowercased())",
                         tint: MonitorFmt.thermalTint(s.thermalState), icon: "clock")
            }
            MonitorLink(route: .processList) {
                StatTile(label: "Processes", value: Format.count(s.processCount),
                         detail: "load \(s.loadAverage.map { MonitorFmt.load($0) }.joined(separator: " "))",
                         history: store.processCountHistory, icon: "list.bullet.rectangle")
            }
            MonitorLink(route: .memoryPressure) {
                StatTile(label: "Swap", value: Format.bytes(s.memory.swapUsed),
                         detail: "of \(Format.bytes(s.memory.swapTotal)) · \(s.memory.pressureTitle.lowercased())",
                         tint: s.memory.pressureLevel >= 2 ? Theme.warning : Theme.ink,
                         history: monitor.swapHistory, icon: "arrow.triangle.swap")
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Quick actions", detail: "jump to a toolkit")
            TileGrid(minWidth: 260) {
                NavRow(icon: "archivebox", title: "Smart Scan", subtitle: "System junk, caches, logs, trash", tint: Theme.accent) { Navigator.shared.go(.cleanup) }
                NavRow(icon: "square.stack.3d.up", title: "Applications", subtitle: "Uninstall apps and leftovers", tint: Theme.info) { Navigator.shared.go(.apps) }
                NavRow(icon: "hand.raised", title: "Privacy", subtitle: "Browser data, recent items", tint: Theme.warning) { Navigator.shared.go(.privacy) }
                NavRow(icon: "speedometer", title: "Performance", subtitle: "Login items, maintenance", tint: Theme.success) { Navigator.shared.go(.performance) }
                NavRow(icon: "internaldrive", title: "Space & Files", subtitle: "Large files, duplicates", tint: Theme.info) { Navigator.shared.go(.space) }
                NavRow(icon: "shield.lefthalf.filled", title: "Protection", subtitle: "Malware and adware scan", tint: Theme.danger) { Navigator.shared.go(.protection) }
            }
        }
    }

    private func explore(_ s: MetricsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Monitor", detail: "every metric, drill down")
            TileGrid(minWidth: 260) {
                NavRow(icon: "flame", title: "Top CPU", subtitle: topName(byCPU: true), value: topValue(byCPU: true), route: .monitor(.topCPU))
                NavRow(icon: "memorychip", title: "Top Memory", subtitle: topName(byCPU: false), value: topValue(byCPU: false), tint: Theme.info, route: .monitor(.topMemory))
                NavRow(icon: "square.grid.3x3", title: "CPU Cores", subtitle: "per-core live load", value: "\(s.cpu.cores.count)", route: .monitor(.cores))
                NavRow(icon: "chart.line.uptrend.xyaxis", title: "Load Average", subtitle: "1 / 5 / 15 minutes", value: MonitorFmt.load(s.loadAverage.first ?? 0), route: .monitor(.loadAverage))
                NavRow(icon: "gauge.with.needle", title: "Memory Pressure", subtitle: "swap and compression", value: s.memory.pressureTitle, tint: Theme.info, route: .monitor(.memoryPressure))
                NavRow(icon: "person.2", title: "Processes by User", subtitle: "grouped totals", route: .monitor(.processUsers))
                NavRow(icon: "externaldrive", title: "Volumes", subtitle: "mounted disks", tint: Theme.warning, route: .monitor(.volumes))
                NavRow(icon: "moon.zzz", title: "Sleep Blockers", subtitle: "power assertions", tint: Theme.muted, route: .monitor(.powerAssertions))
                NavRow(icon: "desktopcomputer", title: "System Info", subtitle: "model, chip, macOS", tint: Theme.muted, route: .monitor(.systemInfo))
                NavRow(icon: "slider.horizontal.3", title: "Sampling", subtitle: "interval, pause, peaks", value: "\(String(format: "%g", monitor.intervalSeconds))s", tint: Theme.muted, route: .monitor(.samplingSettings))
            }
        }
    }

    private func topName(byCPU: Bool) -> String {
        let list = monitor.processes
        let top = byCPU ? list.max { $0.cpu < $1.cpu } : list.max { $0.memory < $1.memory }
        return top.map { "\($0.name) (pid \($0.pid))" } ?? "sampling…"
    }

    private func topValue(byCPU: Bool) -> String? {
        let list = monitor.processes
        if byCPU { return list.max { $0.cpu < $1.cpu }.map { MonitorFmt.psCPU($0.cpu) } }
        return list.max { $0.memory < $1.memory }.map { Format.bytes($0.memory) }
    }

    private var recentActivity: some View {
        Card("Recent activity", trailing: "\(Format.count(log.entries.count)) entries · \(Format.bytes(log.totalFreed)) freed") {
            VStack(alignment: .leading, spacing: 6) {
                if log.entries.isEmpty {
                    Text("No cleanups yet. Run Smart Scan to get started.").font(Type.text(12)).foregroundStyle(Theme.muted)
                } else {
                    ForEach(log.entries.prefix(5)) { entry in
                        MonitorActivityRow(entry: entry)
                    }
                }
                NavRow(icon: "clock.arrow.circlepath", title: "All activity", value: Format.count(log.entries.count), tint: Theme.muted, route: .monitor(.activityLog))
            }
        }
    }
}

struct MonitorActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.failures > 0 ? "exclamationmark.circle" : "checkmark.circle")
                .foregroundStyle(entry.failures > 0 ? Theme.warning : Theme.success)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text("\(entry.module) · \(Format.relative(entry.date))\(entry.detail.isEmpty ? "" : " · \(entry.detail)")")
                    .font(Type.text(10)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            Text("\(Format.count(entry.items)) items").font(Type.mono(10)).foregroundStyle(Theme.muted)
            if entry.failures > 0 {
                RiskBadge(text: "\(entry.failures) failed", tint: Theme.danger)
            }
            Text(Format.bytes(entry.bytes)).font(Type.mono(11, weight: .semibold)).foregroundStyle(Theme.ink).monospacedDigit()
        }
        .padding(.vertical, 3)
    }
}
