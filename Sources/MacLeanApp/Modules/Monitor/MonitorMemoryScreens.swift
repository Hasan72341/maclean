import MacLeanCore
import SwiftUI

struct MonitorMemoryScreen: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var store = MonitorStore.shared

    var body: some View {
        let m = monitor.latest.memory
        ScreenScaffold("Memory", subtitle: "\(Format.bytes(m.total)) installed · \(m.pressureTitle.lowercased()) pressure", actions: { MonitorPauseButton() }) {
            TileGrid {
                StatTile(label: "Used", value: Format.bytes(m.used), detail: MonitorFmt.cpu1(m.usedFraction), tint: Theme.info, history: monitor.memoryHistory, icon: "memorychip")
                StatTile(label: "App memory", value: Format.bytes(m.appMemory), tint: Theme.accent)
                StatTile(label: "Wired", value: Format.bytes(m.wired), tint: Theme.warning)
                StatTile(label: "Compressed", value: Format.bytes(m.compressed), tint: Theme.danger, history: monitor.compressedHistory)
                StatTile(label: "Cached files", value: Format.bytes(m.cached), tint: Theme.success)
                StatTile(label: "Free", value: Format.bytes(m.free))
                StatTile(label: "Swap used", value: Format.bytes(m.swapUsed), detail: "of \(Format.bytes(m.swapTotal))", history: monitor.swapHistory)
                StatTile(label: "Session peak", value: Format.bytes(store.peakMemory), tint: Theme.danger)
            }
            Card("Composition") {
                StackedBar(segments: [
                    .init(label: "App", value: Double(m.appMemory), color: Theme.accent, text: Format.bytes(m.appMemory)),
                    .init(label: "Wired", value: Double(m.wired), color: Theme.warning, text: Format.bytes(m.wired)),
                    .init(label: "Compressed", value: Double(m.compressed), color: Theme.danger, text: Format.bytes(m.compressed)),
                    .init(label: "Cached", value: Double(m.cached), color: Theme.success, text: Format.bytes(m.cached)),
                    .init(label: "Free", value: Double(m.free), color: Theme.line, text: Format.bytes(m.free)),
                ], total: Double(m.total))
            }
            Card("Used memory · live") {
                VStack(alignment: .leading, spacing: 8) {
                    LiveChart(series: [
                        .init(values: monitor.memoryBytesHistory, color: Theme.info, label: "Used"),
                        .init(values: monitor.compressedHistory, color: Theme.danger, label: "Compressed", fill: false),
                    ], maxValue: Double(m.total), format: { MonitorFmt.bytes($0) }, height: 180)
                    MonitorStatsLine(values: monitor.memoryBytesHistory, format: { MonitorFmt.bytes($0) })
                }
            }
            Card("Engine reading (vm_stat)", trailing: store.vmStatsState.loadedAt.map { "read \(Format.relative($0))" }) {
                VStack(alignment: .leading, spacing: 4) {
                    RefreshLine(state: store.vmStatsState) { Task { await store.loadVMStats(force: true) } }
                    if let stats = store.vmStats {
                        KeyValueRow(key: "Total", value: Format.bytes(stats.totalBytes))
                        KeyValueRow(key: "Free + inactive + speculative", value: Format.bytes(stats.freeBytes))
                        KeyValueRow(key: "Wired", value: Format.bytes(stats.wiredBytes))
                        KeyValueRow(key: "Compressor", value: Format.bytes(stats.compressedBytes))
                        KeyValueRow(key: "Page size", value: Format.count(Int(stats.pageSize)) + " bytes")
                    }
                }
            }
            VStack(spacing: 8) {
                NavRow(icon: "gauge.with.needle", title: "Memory pressure & swap", subtitle: "pressure level, swap and compression history, purge", value: m.pressureTitle, tint: Theme.info, route: .monitor(.memoryPressure))
                NavRow(icon: "list.number", title: "Top memory processes", subtitle: "by resident size", value: monitor.processes.max { $0.memory < $1.memory }.map { Format.bytes($0.memory) }, tint: Theme.info, route: .monitor(.topMemory))
                NavRow(icon: "person.2", title: "Memory by user", route: .monitor(.processUsers))
            }
        }
        .task { await store.loadVMStats() }
    }
}

struct MonitorPressureScreen: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var store = MonitorStore.shared

    var body: some View {
        let m = monitor.latest.memory
        let tint: Color = m.pressureLevel >= 4 ? Theme.danger : (m.pressureLevel >= 2 ? Theme.warning : Theme.success)
        ScreenScaffold("Memory Pressure", subtitle: "Kernel pressure level, swap and compressor activity") {
            HStack(alignment: .center, spacing: 22) {
                RingGauge(value: m.pressureLevel >= 4 ? 1 : (m.pressureLevel >= 2 ? 0.66 : 0.33), label: m.pressureTitle, caption: "pressure", tint: tint, size: 130)
                TileGrid {
                    StatTile(label: "Swap used", value: Format.bytes(m.swapUsed), detail: "of \(Format.bytes(m.swapTotal)) allocated", tint: m.swapUsed > 0 ? Theme.warning : Theme.success, history: monitor.swapHistory)
                    StatTile(label: "Compressed", value: Format.bytes(m.compressed), detail: MonitorFmt.cpu1(m.total > 0 ? Double(m.compressed) / Double(m.total) : 0) + " of RAM", tint: Theme.danger, history: monitor.compressedHistory)
                    StatTile(label: "Free", value: Format.bytes(m.free), detail: "+ \(Format.bytes(m.cached)) reclaimable cache")
                    StatTile(label: "Level", value: "\(m.pressureLevel)", detail: "1 normal · 2 warn · 4 critical", tint: tint)
                }
            }
            Card("Swap · live") {
                VStack(alignment: .leading, spacing: 8) {
                    LiveChart(series: [.init(values: monitor.swapHistory, color: Theme.warning, label: "Swap used")], maxValue: max(Double(m.swapTotal), (monitor.swapHistory.max() ?? 0) * 1.1, 1), format: { MonitorFmt.bytes($0) }, height: 140)
                    MonitorStatsLine(values: monitor.swapHistory, format: { MonitorFmt.bytes($0) })
                }
            }
            Card("Compressor · live") {
                VStack(alignment: .leading, spacing: 8) {
                    LiveChart(series: [.init(values: monitor.compressedHistory, color: Theme.danger, label: "Compressed")], format: { MonitorFmt.bytes($0) }, height: 140)
                    MonitorStatsLine(values: monitor.compressedHistory, format: { MonitorFmt.bytes($0) })
                }
            }
            Card("Free up inactive memory") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Runs /usr/sbin/purge, which flushes the file cache so inactive memory becomes free. macOS asks for your administrator password. It does not close apps; caches refill as you work.")
                        .font(Type.text(12)).foregroundStyle(Theme.muted)
                    HStack {
                        ConfirmButton(title: "Purge Memory", message: "macOS will prompt for your administrator password, then run /usr/sbin/purge. Disk activity may spike briefly.", disabled: store.actionBusy) {
                            Task { await store.purgeMemory() }
                        }
                        if store.actionBusy { ProgressView().controlSize(.small) }
                    }
                    MonitorCopyCommand(command: "sudo /usr/sbin/purge")
                }
            }
            if let output = store.lastCommand {
                MonitorCommandCard(output: output)
            }
            NavRow(icon: "list.number", title: "Who is using memory?", subtitle: "Quit heavy processes", tint: Theme.info, route: .monitor(.topMemory))
        }
    }
}
