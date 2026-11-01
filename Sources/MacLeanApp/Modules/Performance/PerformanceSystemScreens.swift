import AppKit
import MacLeanCore
import SwiftUI

// MARK: - Snapshots

struct PerformanceSnapshotsScreen: View {
    @ObservedObject private var store = PerformanceStore.shared
    @EnvironmentObject private var monitor: SystemMonitor
    @State private var selected: Set<String> = []
    @State private var output = ""

    var body: some View {
        let disk = monitor.latest.disk
        let purgeable = max(0, disk.availableImportant - disk.available)
        ScreenScaffold("Local Snapshots", subtitle: "Time Machine keeps hourly APFS snapshots on the startup disk") {
            RefreshLine(state: store.snapshotState) { Task { await store.loadSnapshots() } }
        } content: {
            TileGrid {
                StatTile(label: "Snapshots", value: Format.count(store.snapshots.count), icon: "clock.arrow.circlepath")
                StatTile(label: "Oldest", value: store.snapshots.last?.date.map { Format.relative($0) } ?? "—",
                         detail: Format.date(store.snapshots.last?.date), icon: "calendar")
                StatTile(label: "Newest", value: store.snapshots.first?.date.map { Format.relative($0) } ?? "—",
                         detail: Format.date(store.snapshots.first?.date), icon: "calendar.badge.clock")
                StatTile(label: "Free space", value: Format.bytes(disk.available), detail: "\(Format.bytes(disk.total)) total", icon: "internaldrive")
                StatTile(label: "Purgeable", value: Format.bytes(purgeable), detail: "incl. snapshots & caches",
                         tint: purgeable > 0 ? Theme.accent : Theme.ink, icon: "arrow.3.trianglepath")
            }

            Card {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.info)
                    Text("Deleting a snapshot runs tmutil deletelocalsnapshots as root (macOS asks for your password). Backups on external disks are untouched.")
                        .font(Type.text(11)).foregroundStyle(Theme.muted)
                    Spacer()
                    NavRow(icon: "scissors", title: "Thin snapshots", subtitle: "reclaim up to 10 GB", route: .performance(.thinSnapshots))
                        .flexibleWidth(260)
                }
            }

            FailureList(failures: store.lastFailures)
            if !output.isEmpty { Card("tmutil output") { PerformanceOutputPanel(text: output, height: 100) } }

            switch store.snapshotState {
            case .idle, .loading:
                LoadingPanel(text: "Running tmutil listlocalsnapshots /…")
            case .failed(let message):
                ErrorPanel(message: message) { Task { await store.loadSnapshots() } }
            case .loaded:
                if store.snapshots.isEmpty {
                    EmptyPanel(icon: "checkmark.seal", title: "No local snapshots", message: "The startup disk has no Time Machine local snapshots.")
                } else {
                    Card("Snapshots", trailing: "newest first") {
                        VStack(spacing: 0) {
                            ForEach(store.snapshots) { snap in
                                CheckRow(isOn: Binding(get: { selected.contains(snap.id) }, set: { on in
                                    if on { selected.insert(snap.id) } else { selected.remove(snap.id) }
                                }), title: Format.date(snap.date), subtitle: snap.name,
                                         value: snap.date.map { Format.relative($0) },
                                         badge: PerformanceShell.isSafeToken(snap.dateToken) ? nil : "unparsed")
                            }
                        }
                    }
                    let chosen = store.snapshots.filter { selected.contains($0.id) }
                    SelectionBar(selectedCount: chosen.count, totalCount: store.snapshots.count, selectedBytes: 0,
                                 actionTitle: "Delete Snapshots",
                                 confirmMessage: "Runs tmutil deletelocalsnapshots for each selected date as administrator. Deleted snapshots cannot be restored.",
                                 busy: store.busy,
                                 onSelectAll: { selected = Set(store.snapshots.map(\.id)) },
                                 onSelectNone: { selected = [] }) {
                        Task {
                            if let result = await store.deleteSnapshots(chosen) {
                                output = "exit \(result.status)\n" + result.stdout + result.stderr
                            }
                            selected = []
                        }
                    }
                }
            }
        }
        .onAppear { store.loadSnapshotsIfNeeded() }
    }
}

// MARK: - Memory

struct PerformanceMemoryScreen: View {
    @ObservedObject private var store = PerformanceStore.shared
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let m = monitor.latest.memory
        let running = store.runs[.freeRAM]?.running == true
        ScreenScaffold("Memory", subtitle: "Live memory composition, pressure and the apps using it") {
            ConfirmButton(title: running ? "Freeing…" : "Free Up RAM",
                          message: "Runs purge as administrator to flush inactive disk caches. macOS will ask for your password.",
                          disabled: running) {
                Task { await store.freeRAM() }
            }
        } content: {
            TileGrid {
                StatTile(label: "Used", value: Format.bytes(m.used), detail: Format.percent(m.usedFraction) + " of " + Format.bytes(m.total),
                         tint: PerformanceColors.load(m.usedFraction), history: monitor.memoryHistory, icon: "memorychip")
                StatTile(label: "Pressure", value: m.pressureTitle, detail: "level \(m.pressureLevel)", tint: PerformanceColors.pressure(m.pressureLevel), icon: "gauge")
                StatTile(label: "Compressed", value: Format.bytes(m.compressed), history: monitor.compressedHistory, icon: "rectangle.compress.vertical")
                StatTile(label: "Swap", value: Format.bytes(m.swapUsed), detail: "of \(Format.bytes(m.swapTotal))",
                         tint: m.swapUsed > 0 ? Theme.warning : Theme.ink, history: monitor.swapHistory, icon: "arrow.left.arrow.right")
                StatTile(label: "Free", value: Format.bytes(m.free), detail: "+ \(Format.bytes(m.cached)) cached", tint: Theme.success, icon: "leaf")
                StatTile(label: "Wired", value: Format.bytes(m.wired), detail: "kernel, cannot be paged", icon: "lock")
            }

            Card("Usage · live (2 min)", trailing: "1 s samples") {
                LiveChart(series: [
                    .init(values: monitor.memoryBytesHistory, color: Theme.accent, label: "Used"),
                    .init(values: monitor.compressedHistory, color: Theme.info, label: "Compressed"),
                    .init(values: monitor.swapHistory, color: Theme.warning, label: "Swap", fill: false),
                ], maxValue: Double(m.total), format: { Format.bytes(Int64($0)) }, height: 170)
            }

            HStack(alignment: .top, spacing: 16) {
                Card("Composition") {
                    StackedBar(segments: PerformanceColors.memorySegments(m), total: Double(m.total))
                    HStack(spacing: 24) {
                        RingGauge(value: m.usedFraction, label: Format.percent(m.usedFraction), caption: "used",
                                  tint: PerformanceColors.load(m.usedFraction), size: 110)
                        VStack(alignment: .leading, spacing: 2) {
                            KeyValueRow(key: "Active", value: Format.bytes(m.active))
                            KeyValueRow(key: "Inactive", value: Format.bytes(m.inactive))
                            KeyValueRow(key: "App memory", value: Format.bytes(m.appMemory))
                            KeyValueRow(key: "Cached files", value: Format.bytes(m.cached))
                        }
                    }
                }
                Card("Engine reading (vm_stat)", trailing: store.memoryState.loadedAt.map { Format.relative($0) }) {
                    if let stats = store.memoryStats {
                        KeyValueRow(key: "Total", value: Format.bytes(stats.totalBytes))
                        KeyValueRow(key: "Available", value: Format.bytes(stats.freeBytes))
                        KeyValueRow(key: "Wired", value: Format.bytes(stats.wiredBytes))
                        KeyValueRow(key: "Compressed", value: Format.bytes(stats.compressedBytes))
                        KeyValueRow(key: "Page size", value: Format.bytes(stats.pageSize))
                    } else if store.memoryState.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Not read yet").font(Type.text(12)).foregroundStyle(Theme.muted)
                    }
                    Button("Read again") { Task { await store.loadMemory() } }.buttonStyle(EditorialButtonStyle(kind: .inline))
                }
            }

            if running {
                LoadingPanel(text: "Running purge as administrator…", detail: "Approve the password prompt.")
            }
            if let purge = store.purgeResult {
                Card("Last Free Up RAM", trailing: Format.relative(purge.date)) {
                    TileGrid(minWidth: 140) {
                        StatTile(label: "Before", value: Format.bytes(purge.before), detail: "available")
                        StatTile(label: "After", value: Format.bytes(purge.after), detail: "available", tint: Theme.success)
                        StatTile(label: "Change", value: (purge.delta >= 0 ? "+" : "−") + Format.bytes(abs(purge.delta)),
                                 tint: purge.delta >= 0 ? Theme.success : Theme.warning)
                        StatTile(label: "Exit", value: "\(purge.status)", tint: purge.status == 0 ? Theme.success : Theme.danger)
                    }
                    if !purge.output.isEmpty { PerformanceOutputPanel(text: purge.output, height: 60) }
                }
            }

            Card("Top memory processes · live", trailing: "\(monitor.processes.count) procs") {
                let top = Array(monitor.processes.sorted { $0.memory > $1.memory }.prefix(10))
                let peak = Double(top.first?.memory ?? 1)
                ForEach(top) { proc in
                    BarRow(label: "\(proc.name)  ·  \(proc.user)", value: Double(proc.memory), total: peak,
                           valueText: Format.bytes(proc.memory)) { nav.push(.performance(.processDetail(proc.pid))) }
                }
                Button("All processes by memory") { nav.push(.performance(.topMemory)) }.buttonStyle(EditorialButtonStyle(kind: .inline))
            }
        }
        .task { if store.memoryStats == nil { await store.loadMemory() } }
    }
}

// MARK: - CPU

struct PerformanceCPUScreen: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let cpu = monitor.latest.cpu
        let loads = monitor.latest.loadAverage
        ScreenScaffold("CPU Load", subtitle: "\(cpu.cores.count) logical cores · \(ProcessInfo.processInfo.processorCount) processors") {
            Button("Top CPU processes") { nav.push(.performance(.topCPU)) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
        } content: {
            TileGrid {
                StatTile(label: "Total", value: Format.percent(cpu.total), tint: PerformanceColors.load(cpu.total), history: monitor.cpuHistory, icon: "cpu")
                StatTile(label: "User", value: Format.percent(cpu.user), history: monitor.cpuUserHistory, icon: "person")
                StatTile(label: "System", value: Format.percent(cpu.system), history: monitor.cpuSystemHistory, icon: "gearshape")
                StatTile(label: "Idle", value: Format.percent(cpu.idle), tint: Theme.success, icon: "moon")
                StatTile(label: "Load 1/5/15", value: String(format: "%.2f", loads.first ?? 0),
                         detail: String(format: "%.2f · %.2f", loads.count > 1 ? loads[1] : 0, loads.count > 2 ? loads[2] : 0),
                         history: monitor.loadHistory, icon: "chart.line.uptrend.xyaxis")
                StatTile(label: "Processes", value: Format.count(monitor.latest.processCount), detail: "up \(Format.duration(monitor.latest.uptime))", icon: "list.number")
            }
            Card("Total CPU · live", trailing: "user + system") {
                LiveChart(series: [
                    .init(values: monitor.cpuUserHistory.map { $0 * 100 }, color: Theme.accent, label: "User"),
                    .init(values: monitor.cpuSystemHistory.map { $0 * 100 }, color: Theme.info, label: "System"),
                ], maxValue: 100, format: { String(format: "%.0f%%", $0) }, height: 160)
            }
            Card("Load average · live") {
                LiveChart(series: [.init(values: monitor.loadHistory, color: Theme.warning, label: "1-min load")],
                          maxValue: max(Double(cpu.cores.count), (monitor.loadHistory.max() ?? 1) * 1.2),
                          format: { String(format: "%.2f", $0) }, height: 110)
            }
            SectionHeader(title: "Per core", detail: "\(monitor.coreHistory.count) cores")
            TileGrid(minWidth: 150) {
                ForEach(Array(monitor.coreHistory.enumerated()), id: \.offset) { item in
                    let value = item.element.last ?? 0
                    StatTile(label: "Core \(item.offset)", value: Format.percent(value), tint: PerformanceColors.load(value), history: item.element)
                }
            }
        }
    }
}

// MARK: - Heavy consumers

struct PerformanceHeavyConsumersScreen: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let procs = monitor.processes
        let byCPU = Array(procs.sorted { $0.cpu > $1.cpu }.prefix(10))
        let byMem = Array(procs.sorted { $0.memory > $1.memory }.prefix(10))
        let totalCPU = procs.reduce(0) { $0 + $1.cpu }
        let totalMem = procs.reduce(Int64(0)) { $0 + $1.memory }
        let mine = procs.filter { $0.user == NSUserName() }.count
        ScreenScaffold("Heavy Consumers", subtitle: "Processes using the most CPU and memory right now (refreshes every ~3 s)") {
            Button("Refresh") { Task { await monitor.refreshProcesses() } }.buttonStyle(EditorialButtonStyle(kind: .secondary))
        } content: {
            TileGrid {
                StatTile(label: "Processes", value: Format.count(procs.count), detail: "\(Format.count(mine)) yours", icon: "list.number")
                StatTile(label: "Σ CPU", value: String(format: "%.0f%%", totalCPU), detail: "sum across cores", history: monitor.cpuHistory, icon: "cpu")
                StatTile(label: "Σ Resident", value: Format.bytes(totalMem), detail: "RSS of all processes", history: monitor.memoryBytesHistory, icon: "memorychip")
                StatTile(label: "Top CPU", value: byCPU.first?.name ?? "—", detail: byCPU.first.map { String(format: "%.1f%%", $0.cpu) }, icon: "flame")
                StatTile(label: "Top memory", value: byMem.first?.name ?? "—", detail: byMem.first.map { Format.bytes($0.memory) }, icon: "shippingbox")
            }
            HStack(alignment: .top, spacing: 16) {
                Card("By CPU") {
                    let peak = max(100, byCPU.first?.cpu ?? 100)
                    ForEach(byCPU) { proc in
                        BarRow(label: proc.name, value: proc.cpu, total: peak, valueText: String(format: "%.1f%%", proc.cpu),
                               tint: PerformanceColors.load(proc.cpu / 100)) { nav.push(.performance(.processDetail(proc.pid))) }
                    }
                    Button("All by CPU") { nav.push(.performance(.topCPU)) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                }
                Card("By memory") {
                    let peak = Double(byMem.first?.memory ?? 1)
                    ForEach(byMem) { proc in
                        BarRow(label: proc.name, value: Double(proc.memory), total: peak, valueText: Format.bytes(proc.memory),
                               tint: Theme.info) { nav.push(.performance(.processDetail(proc.pid))) }
                    }
                    Button("All by memory") { nav.push(.performance(.topMemory)) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                }
            }
        }
    }
}

struct PerformanceProcessListScreen: View {
    let byMemory: Bool
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var nav: Navigator
    @State private var query = ""
    @State private var onlyMine = false

    var body: some View {
        let all = monitor.processes
        let list = all
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || "\($0.pid)" == query }
            .filter { !onlyMine || $0.user == NSUserName() }
            .sorted { byMemory ? $0.memory > $1.memory : $0.cpu > $1.cpu }
        let shown = Array(list.prefix(150))
        ScreenScaffold(byMemory ? "Top Memory Processes" : "Top CPU Processes", subtitle: "Live from ps · click a process for details") {
            Button("Refresh") { Task { await monitor.refreshProcesses() } }.buttonStyle(EditorialButtonStyle(kind: .secondary))
        } content: {
            TileGrid {
                StatTile(label: "Matching", value: Format.count(list.count), detail: "of \(Format.count(all.count))", icon: "line.3.horizontal.decrease")
                if byMemory {
                    StatTile(label: "Σ Resident", value: Format.bytes(list.reduce(Int64(0)) { $0 + $1.memory }), history: monitor.memoryBytesHistory, icon: "memorychip")
                } else {
                    StatTile(label: "Σ CPU", value: String(format: "%.0f%%", list.reduce(0) { $0 + $1.cpu }), history: monitor.cpuHistory, icon: "cpu")
                }
                StatTile(label: "Users", value: Format.count(Set(list.map(\.user)).count), icon: "person.2")
            }
            HStack {
                SearchField(text: $query, prompt: "Filter by name or pid")
                Toggle("Only my processes", isOn: $onlyMine).toggleStyle(.checkbox)
                Spacer()
            }
            if all.isEmpty {
                LoadingPanel(text: "Sampling processes…")
            } else if shown.isEmpty {
                EmptyPanel(icon: "magnifyingglass", title: "No matches")
            } else {
                Card(nil, trailing: "\(shown.count) shown") {
                    let peakCPU = max(100, shown.map(\.cpu).max() ?? 100)
                    let peakMem = Double(shown.map(\.memory).max() ?? 1)
                    ForEach(shown) { proc in
                        BarRow(label: "\(proc.name)  ·  pid \(proc.pid)  ·  \(proc.user)",
                               value: byMemory ? Double(proc.memory) : proc.cpu, total: byMemory ? peakMem : peakCPU,
                               valueText: byMemory ? Format.bytes(proc.memory) : String(format: "%.1f%% · %@", proc.cpu, Format.bytes(proc.memory)),
                               tint: byMemory ? Theme.info : PerformanceColors.load(proc.cpu / 100)) {
                            nav.push(.performance(.processDetail(proc.pid)))
                        }
                    }
                }
            }
        }
    }
}

struct PerformanceProcessDetailScreen: View {
    let pid: Int32
    @ObservedObject private var store = PerformanceStore.shared
    @EnvironmentObject private var monitor: SystemMonitor
    @State private var cpuHistory: [Double] = []
    @State private var memHistory: [Double] = []
    @State private var info: (path: String, started: String, threads: String, ppid: String, state: String)?

    var body: some View {
        let proc = monitor.processes.first { $0.pid == pid }
        let mine = proc?.user == NSUserName()
        let app = NSRunningApplication(processIdentifier: pid)
        ScreenScaffold(proc?.name ?? app?.localizedName ?? "Process \(pid)", subtitle: info?.path.isEmpty == false ? Format.abbreviated(info!.path) : "pid \(pid)") {
            if let path = info?.path, path.hasPrefix("/") {
                Button("Reveal") { EngineActions.reveal(path) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
            }
        } content: {
            if proc == nil && !monitor.processes.isEmpty {
                EmptyPanel(icon: "xmark.circle", title: "Process has exited", message: "pid \(pid) is no longer running.")
            }
            TileGrid {
                StatTile(label: "CPU", value: String(format: "%.1f%%", proc?.cpu ?? 0), tint: PerformanceColors.load((proc?.cpu ?? 0) / 100), history: cpuHistory, icon: "cpu")
                StatTile(label: "Resident memory", value: Format.bytes(proc?.memory ?? 0),
                         detail: Format.percent(Double(proc?.memory ?? 0) / Double(max(1, monitor.latest.memory.total)), digits: 1) + " of RAM",
                         history: memHistory, icon: "memorychip")
                StatTile(label: "User", value: proc?.user ?? "—", icon: "person")
                StatTile(label: "Threads", value: info?.threads ?? "…", icon: "line.3.horizontal")
            }
            Card("CPU & memory · live", trailing: "\(cpuHistory.count) samples") {
                LiveChart(series: [.init(values: cpuHistory, color: Theme.accent, label: "CPU")],
                          maxValue: max(100, (cpuHistory.max() ?? 0) * 1.1), capacity: 60, format: { String(format: "%.1f%%", $0) }, height: 100)
                LiveChart(series: [.init(values: memHistory, color: Theme.info, label: "Memory")],
                          capacity: 60, format: { Format.bytes(Int64($0)) }, height: 100)
            }
            Card("Details") {
                KeyValueRow(key: "PID", value: "\(pid)", mono: true)
                KeyValueRow(key: "Parent PID", value: info?.ppid ?? "—", mono: true)
                KeyValueRow(key: "State", value: info?.state ?? "—", mono: true)
                KeyValueRow(key: "Started", value: info?.started ?? "—")
                KeyValueRow(key: "Executable", value: info?.path ?? "—", mono: true)
                if let app {
                    KeyValueRow(key: "Application", value: app.localizedName ?? "—")
                    KeyValueRow(key: "Bundle ID", value: app.bundleIdentifier ?? "—", mono: true)
                }
            }
            Card("Actions") {
                HStack(spacing: 10) {
                    ConfirmButton(title: "Quit", message: "Sends SIGTERM to \(proc?.name ?? "pid \(pid)"). Unsaved work in that app may be lost.",
                                  kind: .secondary, disabled: !mine || proc == nil) {
                        store.terminate(pid: pid, name: proc?.name ?? "\(pid)", force: false)
                    }
                    ConfirmButton(title: "Force Quit", message: "Sends SIGKILL to \(proc?.name ?? "pid \(pid)"). The process ends immediately without saving.",
                                  kind: .destructive, disabled: !mine || proc == nil) {
                        store.terminate(pid: pid, name: proc?.name ?? "\(pid)", force: true)
                    }
                    Spacer()
                    if !mine && proc != nil {
                        Text("Owned by \(proc?.user ?? "another user") — MacLean only quits your own processes.")
                            .font(Type.text(11)).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .task {
            let id = pid
            let result = await engine { PerformanceShell.processInfo(pid: id) }
            info = result
        }
        .onReceive(monitor.$processes) { list in
            guard let p = list.first(where: { $0.pid == pid }) else { return }
            cpuHistory.append(p.cpu)
            memHistory.append(Double(p.memory))
            if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }
            if memHistory.count > 60 { memHistory.removeFirst(memHistory.count - 60) }
        }
    }
}

// MARK: - Energy

struct PerformanceEnergyScreen: View {
    @ObservedObject private var store = PerformanceStore.shared
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let s = monitor.latest
        let battery = s.battery
        ScreenScaffold("Energy", subtitle: "Battery, thermal state, CPU draw and apps keeping your Mac awake") {
            Button("Sleep blockers") { nav.push(.performance(.sleepAssertions)) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
        } content: {
            TileGrid {
                if let battery {
                    StatTile(label: "Battery", value: "\(battery.percent)%",
                             detail: battery.isCharging ? "charging" : battery.onAC ? "on AC" : battery.minutesRemaining.map { "\(Format.duration(TimeInterval($0 * 60))) left" } ?? "on battery",
                             tint: battery.percent < 20 ? Theme.danger : Theme.success, icon: battery.isCharging ? "battery.100.bolt" : "battery.75")
                    StatTile(label: "Health", value: battery.healthFraction.map { Format.percent($0) } ?? "—", detail: battery.condition ?? "condition n/a", icon: "heart")
                    StatTile(label: "Cycles", value: battery.cycleCount.map { Format.count($0) } ?? "—", icon: "arrow.clockwise")
                    StatTile(label: "Temperature", value: battery.temperatureC.map { String(format: "%.1f °C", $0) } ?? "—", icon: "thermometer")
                } else {
                    StatTile(label: "Power", value: "AC", detail: "no internal battery", icon: "powerplug")
                }
                StatTile(label: "Thermal", value: s.thermalTitle, tint: s.thermalState == .nominal ? Theme.success : Theme.warning, icon: "thermometer.medium")
                StatTile(label: "CPU", value: Format.percent(s.cpu.total), history: monitor.cpuHistory, icon: "cpu")
                StatTile(label: "Sleep blockers", value: store.assertionState.loadedAt == nil ? "…" : Format.count(store.assertions.count), icon: "moon.zzz")
            }
            if let battery, let health = battery.healthFraction {
                Card("Battery") {
                    HStack(spacing: 24) {
                        RingGauge(value: Double(battery.percent) / 100, label: "\(battery.percent)%", caption: "charge", tint: Theme.success, size: 110)
                        RingGauge(value: health, label: Format.percent(health), caption: "health", tint: health < 0.8 ? Theme.warning : Theme.accent, size: 110)
                        VStack(alignment: .leading) {
                            KeyValueRow(key: "Design capacity", value: battery.designCapacity.map { "\($0) mAh" } ?? "—")
                            KeyValueRow(key: "Max capacity", value: battery.maxCapacity.map { "\($0) mAh" } ?? "—")
                            KeyValueRow(key: "Power source", value: battery.onAC ? "AC adapter" : "Battery")
                        }
                    }
                }
            }
            Card("CPU draw · live") {
                LiveChart(series: [
                    .init(values: monitor.cpuHistory.map { $0 * 100 }, color: Theme.accent, label: "CPU"),
                ], maxValue: 100, format: { String(format: "%.0f%%", $0) }, height: 130)
            }
            Card("Highest energy impact (CPU) · live") {
                let top = Array(monitor.processes.sorted { $0.cpu > $1.cpu }.prefix(8))
                let peak = max(100, top.first?.cpu ?? 100)
                ForEach(top) { proc in
                    BarRow(label: proc.name, value: proc.cpu, total: peak, valueText: String(format: "%.1f%%", proc.cpu),
                           tint: PerformanceColors.load(proc.cpu / 100)) { nav.push(.performance(.processDetail(proc.pid))) }
                }
            }
        }
        .task { if store.assertionState.loadedAt == nil { await store.loadAssertions() } }
    }
}

struct PerformanceAssertionsScreen: View {
    @ObservedObject private var store = PerformanceStore.shared
    @EnvironmentObject private var nav: Navigator

    private func pid(of line: String) -> Int32? {
        let digits = line.dropFirst(4).prefix { $0.isNumber }
        return Int32(digits)
    }

    var body: some View {
        let byType = Dictionary(grouping: store.assertions) { line -> String in
            ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "PreventSystemSleep", "NoIdleSleepAssertion", "NoDisplaySleepAssertion", "UserIsActive", "BackgroundTask"]
                .first { line.contains($0) } ?? "Other"
        }
        ScreenScaffold("Sleep Blockers", subtitle: "Power assertions from pmset -g assertions") {
            RefreshLine(state: store.assertionState) { Task { await store.loadAssertions() } }
        } content: {
            TileGrid {
                StatTile(label: "Assertions", value: Format.count(store.assertions.count), icon: "moon.zzz")
                StatTile(label: "Processes", value: Format.count(Set(store.assertions.compactMap(pid(of:))).count), icon: "app")
                StatTile(label: "Prevent sleep", value: Format.count(store.assertions.filter { $0.contains("PreventUserIdleSystemSleep") || $0.contains("PreventSystemSleep") }.count),
                         tint: Theme.warning, icon: "bed.double")
                StatTile(label: "Keep display on", value: Format.count(store.assertions.filter { $0.contains("DisplaySleep") }.count), icon: "display")
            }
            switch store.assertionState {
            case .idle, .loading: LoadingPanel(text: "Reading power assertions…")
            case .failed(let message): ErrorPanel(message: message) { Task { await store.loadAssertions() } }
            case .loaded:
                if store.assertions.isEmpty {
                    EmptyPanel(icon: "checkmark.seal", title: "Nothing is keeping your Mac awake")
                } else {
                    ForEach(byType.keys.sorted(), id: \.self) { key in
                        Card(key, trailing: "\(byType[key]?.count ?? 0)") {
                            ForEach(byType[key] ?? [], id: \.self) { line in
                                HStack(alignment: .top) {
                                    Text(line).font(Type.mono(10)).foregroundStyle(Theme.ink).textSelection(.enabled).lineLimit(3)
                                    Spacer()
                                    if let id = pid(of: line) {
                                        Button("pid \(id)") { nav.push(.performance(.processDetail(id))) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task { await store.loadAssertions() }
    }
}
