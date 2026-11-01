import AppKit
import MacLeanCore
import SwiftUI

// MARK: - Disk overview

struct MonitorDiskScreen: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var store = MonitorStore.shared

    var body: some View {
        let d = monitor.latest.disk
        ScreenScaffold("Disk", subtitle: "Startup volume · \(Format.bytes(d.total)) capacity", actions: { MonitorPauseButton() }) {
            HStack(alignment: .center, spacing: 22) {
                RingGauge(value: d.usedFraction, label: MonitorFmt.cpu(d.usedFraction), caption: "used", tint: MonitorFmt.tint(forFraction: d.usedFraction), size: 140, lineWidth: 12)
                TileGrid {
                    StatTile(label: "Used", value: Format.bytes(d.used), tint: MonitorFmt.tint(forFraction: d.usedFraction), icon: "internaldrive")
                    StatTile(label: "Free", value: Format.bytes(d.available), detail: "incl. purgeable space", tint: Theme.success)
                    StatTile(label: "Important avail.", value: Format.bytes(d.availableImportant), detail: "what macOS can free for you")
                    StatTile(label: "Capacity", value: Format.bytes(d.total))
                }
            }
            Card("Space") {
                StackedBar(segments: [
                    .init(label: "Used", value: Double(d.used), color: MonitorFmt.tint(forFraction: d.usedFraction), text: Format.bytes(d.used)),
                    .init(label: "Free", value: Double(d.available), color: Theme.line, text: Format.bytes(d.available)),
                ], total: Double(d.total))
            }
            TileGrid {
                StatTile(label: "Read", value: Format.rate(d.readPerSec), tint: Theme.info, history: monitor.diskReadHistory, icon: "arrow.down.doc")
                StatTile(label: "Write", value: Format.rate(d.writePerSec), tint: Theme.warning, history: monitor.diskWriteHistory, icon: "arrow.up.doc")
                StatTile(label: "Read since boot", value: Format.bytes(d.totalRead))
                StatTile(label: "Written since boot", value: Format.bytes(d.totalWritten))
            }
            Card("Read / write · live") {
                LiveChart(series: [
                    .init(values: monitor.diskReadHistory, color: Theme.info, label: "Read"),
                    .init(values: monitor.diskWriteHistory, color: Theme.warning, label: "Write"),
                ], format: { Format.rate($0) }, height: 160)
            }
            Card("Trash", trailing: store.trash.map { "\(Format.count($0.files)) files" }) {
                VStack(alignment: .leading, spacing: 10) {
                    RefreshLine(state: store.trashState) { Task { await store.loadTrash(force: true) } }
                    HStack(alignment: .firstTextBaseline) {
                        Text(store.trash.map { Format.bytes($0.bytes) } ?? "—")
                            .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("in ~/.Trash").font(Type.text(11)).foregroundStyle(Theme.muted)
                        Spacer()
                        ConfirmButton(
                            title: "Empty Trash",
                            message: "Permanently deletes \(store.trash.map { "\(Format.count($0.files)) files (\(Format.bytes($0.bytes)))" } ?? "everything") in your Trash. This cannot be undone.",
                            kind: .destructive,
                            disabled: store.actionBusy || (store.trash?.bytes ?? 0) == 0
                        ) { Task { await store.emptyTrash() } }
                    }
                    if !store.lastFailures.isEmpty { FailureList(failures: store.lastFailures) }
                }
            }
            Card("Local Time Machine snapshots", trailing: "\(store.snapshots.count)") {
                VStack(alignment: .leading, spacing: 6) {
                    RefreshLine(state: store.snapshotsState) { Task { await store.loadSnapshots(force: true) } }
                    if store.snapshotsState.loadedAt != nil && store.snapshots.isEmpty {
                        Text("No local snapshots on the startup disk.").font(Type.text(12)).foregroundStyle(Theme.muted)
                    }
                    ForEach(store.snapshots.prefix(8), id: \.self) { name in
                        Text(name).font(Type.mono(10)).foregroundStyle(Theme.ink).textSelection(.enabled)
                    }
                    if !store.snapshots.isEmpty {
                        NavRow(icon: "clock.arrow.circlepath", title: "Thin snapshots in Performance", subtitle: "snapshots hold purgeable space", tint: Theme.success) { Navigator.shared.go(.performance) }
                    }
                }
            }
            VStack(spacing: 8) {
                NavRow(icon: "externaldrive", title: "All volumes", subtitle: "internal, external and network disks", value: store.volumesState.loadedAt == nil ? nil : "\(store.volumes.count)", tint: Theme.warning, route: .monitor(.volumes))
                NavRow(icon: "arrow.left.arrow.right", title: "Disk activity", subtitle: "throughput history", value: Format.rate(d.readPerSec + d.writePerSec), tint: Theme.info, route: .monitor(.diskIO))
                NavRow(icon: "internaldrive", title: "Free up space", subtitle: "Space & Files: large files, duplicates", tint: Theme.accent) { Navigator.shared.go(.space) }
                NavRow(icon: "archivebox", title: "Clean junk", subtitle: "Smart Scan caches and logs", tint: Theme.accent) { Navigator.shared.go(.cleanup) }
            }
        }
        .task {
            await store.loadTrash()
            await store.loadSnapshots()
            await store.loadVolumes()
        }
    }
}

struct MonitorDiskIOScreen: View {
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        let d = monitor.latest.disk
        let combined = zip(monitor.diskReadHistory, monitor.diskWriteHistory).map { $0 + $1 }
        let interval = monitor.intervalSeconds
        ScreenScaffold("Disk Activity", subtitle: "Block storage throughput from IOKit") {
            TileGrid {
                StatTile(label: "Read now", value: Format.rate(d.readPerSec), tint: Theme.info, history: monitor.diskReadHistory)
                StatTile(label: "Write now", value: Format.rate(d.writePerSec), tint: Theme.warning, history: monitor.diskWriteHistory)
                StatTile(label: "Peak read", value: Format.rate(monitor.diskReadHistory.max() ?? 0))
                StatTile(label: "Peak write", value: Format.rate(monitor.diskWriteHistory.max() ?? 0))
                StatTile(label: "Window read", value: MonitorFmt.bytes(monitor.diskReadHistory.reduce(0, +) * interval), detail: "last \(monitor.diskReadHistory.count) samples")
                StatTile(label: "Window written", value: MonitorFmt.bytes(monitor.diskWriteHistory.reduce(0, +) * interval))
            }
            Card("Read") {
                VStack(alignment: .leading, spacing: 8) {
                    LiveChart(series: [.init(values: monitor.diskReadHistory, color: Theme.info, label: "Read")], format: { Format.rate($0) }, height: 130)
                    MonitorStatsLine(values: monitor.diskReadHistory, format: { Format.rate($0) })
                }
            }
            Card("Write") {
                VStack(alignment: .leading, spacing: 8) {
                    LiveChart(series: [.init(values: monitor.diskWriteHistory, color: Theme.warning, label: "Write")], format: { Format.rate($0) }, height: 130)
                    MonitorStatsLine(values: monitor.diskWriteHistory, format: { Format.rate($0) })
                }
            }
            Card("Combined") {
                MonitorStatsLine(values: combined, format: { Format.rate($0) })
            }
            Card("Since boot") {
                VStack(spacing: 2) {
                    KeyValueRow(key: "Bytes read", value: "\(Format.bytes(d.totalRead)) (\(CountFormat.string(d.totalRead)) B)")
                    KeyValueRow(key: "Bytes written", value: "\(Format.bytes(d.totalWritten)) (\(CountFormat.string(d.totalWritten)) B)")
                    KeyValueRow(key: "Write / read ratio", value: d.totalRead > 0 ? String(format: "%.2f", Double(d.totalWritten) / Double(d.totalRead)) : "—")
                    KeyValueRow(key: "Uptime", value: Format.duration(monitor.latest.uptime))
                }
            }
        }
    }
}

// MARK: - Volumes

struct MonitorVolumesScreen: View {
    @ObservedObject private var store = MonitorStore.shared

    var body: some View {
        let total = store.volumes.reduce(0) { $0 + $1.total }
        let free = store.volumes.reduce(0) { $0 + $1.available }
        ScreenScaffold("Volumes", subtitle: "Mounted, visible volumes", actions: {
            RefreshLine(state: store.volumesState) { Task { await store.loadVolumes(force: true) } }
        }) {
            TileGrid {
                StatTile(label: "Volumes", value: "\(store.volumes.count)", icon: "externaldrive")
                StatTile(label: "Total capacity", value: Format.bytes(total))
                StatTile(label: "Total free", value: Format.bytes(free), tint: Theme.success)
                StatTile(label: "Ejectable", value: "\(store.volumes.filter { $0.isEjectable || $0.isRemovable }.count)", tint: Theme.warning)
            }
            switch store.volumesState {
            case .loading(let text) where store.volumes.isEmpty:
                LoadingPanel(text: text)
            case .failed(let message):
                ErrorPanel(message: message) { Task { await store.loadVolumes(force: true) } }
            default:
                if store.volumes.isEmpty {
                    EmptyPanel(icon: "externaldrive", title: "No volumes reported")
                } else {
                    VStack(spacing: 10) {
                        ForEach(store.volumes) { volume in
                            MonitorLink(route: .volumeDetail(volume.path)) {
                                Card {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Image(systemName: volume.isRoot ? "internaldrive.fill" : (volume.isRemovable ? "externaldrive" : (volume.isLocal ? "internaldrive" : "network")))
                                                .foregroundStyle(Theme.accent)
                                            Text(volume.name).font(Type.text(13, weight: .semibold))
                                            Text(volume.format).font(Type.text(11)).foregroundStyle(Theme.muted)
                                            if volume.isRoot { RiskBadge(text: "startup", tint: Theme.info) }
                                            if volume.isReadOnly { RiskBadge(text: "read-only", tint: Theme.muted) }
                                            if volume.isEjectable || volume.isRemovable { RiskBadge(text: "ejectable", tint: Theme.warning) }
                                            Spacer()
                                        }
                                        BarRow(label: volume.path, value: Double(volume.used), total: Double(max(1, volume.total)),
                                               valueText: "\(Format.bytes(volume.used)) used · \(Format.bytes(volume.available)) free · \(MonitorFmt.cpu(volume.usedFraction))",
                                               tint: MonitorFmt.tint(forFraction: volume.usedFraction))
                                    }
                                    .padding(.trailing, 20)
                                }
                            }
                        }
                    }
                }
            }
        }
        .task { await store.loadVolumes() }
    }
}

struct MonitorVolumeDetailScreen: View {
    let path: String
    @ObservedObject private var store = MonitorStore.shared

    var body: some View {
        let volume = store.volumes.first { $0.path == path }
        ScreenScaffold(volume?.name ?? (path as NSString).lastPathComponent, subtitle: path) {
            if let volume {
                HStack(alignment: .center, spacing: 22) {
                    RingGauge(value: volume.usedFraction, label: MonitorFmt.cpu(volume.usedFraction), caption: "used", tint: MonitorFmt.tint(forFraction: volume.usedFraction), size: 130)
                    TileGrid {
                        StatTile(label: "Capacity", value: Format.bytes(volume.total), icon: "externaldrive")
                        StatTile(label: "Used", value: Format.bytes(volume.used), tint: MonitorFmt.tint(forFraction: volume.usedFraction))
                        StatTile(label: "Free", value: Format.bytes(volume.available), tint: Theme.success)
                        StatTile(label: "Important avail.", value: Format.bytes(volume.availableImportant))
                    }
                }
                Card("Capacity") {
                    StackedBar(segments: [
                        .init(label: "Used", value: Double(volume.used), color: MonitorFmt.tint(forFraction: volume.usedFraction), text: Format.bytes(volume.used)),
                        .init(label: "Free", value: Double(volume.available), color: Theme.line, text: Format.bytes(volume.available)),
                    ], total: Double(max(1, volume.total)))
                }
                Card("Properties") {
                    VStack(spacing: 2) {
                        KeyValueRow(key: "Mount point", value: volume.path, mono: true)
                        KeyValueRow(key: "Format", value: volume.format)
                        KeyValueRow(key: "UUID", value: volume.uuid ?? "—", mono: true)
                        KeyValueRow(key: "Startup volume", value: volume.isRoot ? "Yes" : "No")
                        KeyValueRow(key: "Internal", value: volume.isInternal ? "Yes" : "No")
                        KeyValueRow(key: "Local", value: volume.isLocal ? "Yes" : "Network")
                        KeyValueRow(key: "Removable", value: volume.isRemovable ? "Yes" : "No")
                        KeyValueRow(key: "Ejectable", value: volume.isEjectable ? "Yes" : "No")
                        KeyValueRow(key: "Read-only", value: volume.isReadOnly ? "Yes" : "No")
                        KeyValueRow(key: "Bytes free", value: CountFormat.string(volume.available), mono: true)
                    }
                }
                Card("Actions") {
                    HStack(spacing: 12) {
                        Button("Open in Finder") { EngineActions.open(volume.path) }
                            .buttonStyle(EditorialButtonStyle(kind: .secondary))
                        if (volume.isEjectable || volume.isRemovable) && !volume.isRoot {
                            ConfirmButton(title: "Eject", message: "Unmount and eject \(volume.name). Close any files open on it first.", kind: .destructive, disabled: store.actionBusy) {
                                Task { await store.eject(volume) }
                            }
                        } else {
                            Text(volume.isRoot ? "The startup disk cannot be ejected." : "This volume is not ejectable.")
                                .font(Type.text(11)).foregroundStyle(Theme.muted)
                        }
                        if store.actionBusy { ProgressView().controlSize(.small) }
                    }
                }
                if !store.lastFailures.isEmpty { FailureList(failures: store.lastFailures) }
                if volume.isRoot {
                    NavRow(icon: "internaldrive", title: "Free up space on this disk", subtitle: "Space & Files", tint: Theme.accent) { Navigator.shared.go(.space) }
                }
            } else if store.volumesState.isLoading {
                LoadingPanel(text: "Reading volume…")
            } else {
                EmptyPanel(icon: "eject", title: "Volume is no longer mounted", message: path, actionTitle: "Rescan volumes") {
                    Task { await store.loadVolumes(force: true) }
                }
            }
        }
        .task { await store.loadVolumes() }
    }
}

// MARK: - Network

struct MonitorNetworkScreen: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var store = MonitorStore.shared

    var body: some View {
        let n = monitor.latest.network
        let interval = monitor.intervalSeconds
        ScreenScaffold("Network", subtitle: "All non-loopback interfaces · live", actions: { MonitorPauseButton() }) {
            TileGrid {
                StatTile(label: "Download", value: Format.rate(n.rxPerSec), tint: Theme.success, history: monitor.netRxHistory, icon: "arrow.down.circle")
                StatTile(label: "Upload", value: Format.rate(n.txPerSec), tint: Theme.accent, history: monitor.netTxHistory, icon: "arrow.up.circle")
                StatTile(label: "Received", value: Format.bytes(n.rxTotal), detail: "since boot (all interfaces)")
                StatTile(label: "Sent", value: Format.bytes(n.txTotal), detail: "since boot (all interfaces)")
                StatTile(label: "Peak down", value: Format.rate(store.peakRx), detail: "this session", tint: Theme.success)
                StatTile(label: "Peak up", value: Format.rate(store.peakTx), detail: "this session", tint: Theme.accent)
            }
            Card("Throughput · live") {
                VStack(alignment: .leading, spacing: 8) {
                    LiveChart(series: [
                        .init(values: monitor.netRxHistory, color: Theme.success, label: "Down"),
                        .init(values: monitor.netTxHistory, color: Theme.accent, label: "Up"),
                    ], format: { Format.rate($0) }, height: 180)
                    HStack(spacing: 18) {
                        KeyValueRow(key: "Window down", value: MonitorFmt.bytes(monitor.netRxHistory.reduce(0, +) * interval))
                        KeyValueRow(key: "Window up", value: MonitorFmt.bytes(monitor.netTxHistory.reduce(0, +) * interval))
                        KeyValueRow(key: "Avg down", value: Format.rate(MonitorFmt.average(monitor.netRxHistory)))
                    }
                }
            }
            SectionHeader(title: "Interfaces", detail: "\(n.interfaces.count) with traffic")
            if n.interfaces.isEmpty {
                LoadingPanel(text: "Waiting for interface counters…")
            } else {
                let peak = Double(n.interfaces.map { $0.rxBytes + $0.txBytes }.max() ?? 1)
                VStack(spacing: 8) {
                    ForEach(n.interfaces) { iface in
                        let info = store.interfaces[iface.name]
                        MonitorLink(route: .interfaceDetail(iface.name)) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    BarRow(label: "\(iface.name)\(info?.ipv4.first.map { "  ·  \($0)" } ?? "")", value: Double(iface.rxBytes + iface.txBytes), total: peak,
                                           valueText: "↓ \(Format.bytes(iface.rxBytes))  ↑ \(Format.bytes(iface.txBytes))", tint: Theme.success)
                                }
                                Sparkline(values: store.interfaceRx[iface.name] ?? [], tint: Theme.success)
                                    .frame(width: 90, height: 24)
                                Text(Format.rate(store.interfaceRx[iface.name]?.last ?? 0))
                                    .font(Type.mono(10)).foregroundStyle(Theme.muted).frame(width: 80, alignment: .trailing)
                            }
                            .padding(10)
                            .padding(.trailing, 16)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.canvas))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                        }
                    }
                }
            }
            NavRow(icon: "hand.raised", title: "Network privacy", subtitle: "Clear browser data and Wi-Fi history in Privacy", tint: Theme.warning) { Navigator.shared.go(.privacy) }
        }
        .task { await store.loadInterfaces() }
    }
}

struct MonitorInterfaceScreen: View {
    let name: String
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var store = MonitorStore.shared

    var body: some View {
        let counters = monitor.latest.network.interfaces.first { $0.name == name }
        let info = store.interfaces[name]
        let rx = store.interfaceRx[name] ?? []
        let tx = store.interfaceTx[name] ?? []
        ScreenScaffold(name, subtitle: info.map { $0.isUp ? ($0.isRunning ? "up · running" : "up") : "down" } ?? "network interface", actions: {
            RefreshLine(state: store.interfacesState) { Task { await store.loadInterfaces(force: true) } }
        }) {
            TileGrid {
                StatTile(label: "Download", value: Format.rate(rx.last ?? 0), tint: Theme.success, history: rx, icon: "arrow.down.circle")
                StatTile(label: "Upload", value: Format.rate(tx.last ?? 0), tint: Theme.accent, history: tx, icon: "arrow.up.circle")
                StatTile(label: "Received", value: Format.bytes(counters?.rxBytes ?? 0))
                StatTile(label: "Sent", value: Format.bytes(counters?.txBytes ?? 0))
                StatTile(label: "Packets in", value: Format.count(Int(info?.packetsIn ?? 0)), detail: "\(info?.errorsIn ?? 0) errors")
                StatTile(label: "Packets out", value: Format.count(Int(info?.packetsOut ?? 0)), detail: "\(info?.errorsOut ?? 0) errors")
            }
            Card("\(name) · live") {
                VStack(alignment: .leading, spacing: 8) {
                    LiveChart(series: [
                        .init(values: rx, color: Theme.success, label: "Down"),
                        .init(values: tx, color: Theme.accent, label: "Up"),
                    ], capacity: MonitorStore.historyLength, format: { Format.rate($0) }, height: 170)
                    MonitorStatsLine(values: rx, format: { Format.rate($0) })
                }
            }
            Card("Addresses & link") {
                VStack(spacing: 2) {
                    if let info {
                        ForEach(info.ipv4, id: \.self) { KeyValueRow(key: "IPv4", value: $0, mono: true) }
                        ForEach(info.ipv6, id: \.self) { KeyValueRow(key: "IPv6", value: $0, mono: true) }
                        KeyValueRow(key: "Hardware address", value: info.mac ?? "—", mono: true)
                        KeyValueRow(key: "MTU", value: info.mtu.map { "\($0)" } ?? "—")
                        KeyValueRow(key: "Link speed", value: info.baudrate.flatMap { $0 > 0 ? "\(Format.count(Int($0 / 1_000_000))) Mbit/s" : nil } ?? "—")
                        KeyValueRow(key: "State", value: "\(info.isUp ? "Up" : "Down")\(info.isRunning ? ", running" : "")")
                    } else if store.interfacesState.isLoading {
                        LoadingPanel(text: "Reading interface…")
                    } else {
                        Text("Interface \(name) is not currently present.").font(Type.text(12)).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .task { await store.loadInterfaces() }
    }
}
