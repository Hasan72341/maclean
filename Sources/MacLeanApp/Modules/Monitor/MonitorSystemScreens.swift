import AppKit
import MacLeanCore
import SwiftUI

// MARK: - Battery

struct MonitorBatteryScreen: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var store = MonitorStore.shared

    var body: some View {
        let s = monitor.latest
        ScreenScaffold("Battery", subtitle: s.battery == nil ? "No internal battery" : "Internal battery · IOKit power sources") {
            if let b = s.battery {
                HStack(alignment: .center, spacing: 22) {
                    RingGauge(value: Double(b.percent) / 100, label: "\(b.percent)%", caption: b.isCharging ? "charging" : (b.onAC ? "on AC" : "battery"),
                              tint: b.percent < 20 ? Theme.danger : (b.percent < 40 ? Theme.warning : Theme.success), size: 140, lineWidth: 12)
                    TileGrid {
                        StatTile(label: "Charge", value: "\(b.percent)%", tint: Theme.success, history: store.batteryHistory, icon: "battery.75")
                        StatTile(label: "Time remaining", value: b.minutesRemaining.map { Format.duration(Double($0) * 60) } ?? (b.onAC ? "On AC" : "Calculating"))
                        StatTile(label: "Cycle count", value: b.cycleCount.map { Format.count($0) } ?? "—", detail: "rated ~1,000 on modern Macs")
                        StatTile(label: "Health", value: b.healthFraction.map { Format.percent($0) } ?? "—", detail: b.condition ?? "max vs design capacity",
                                 tint: (b.healthFraction ?? 1) < 0.8 ? Theme.warning : Theme.success)
                    }
                }
                Card("Charge · live", trailing: "updates every 10 samples") {
                    LiveChart(series: [.init(values: store.batteryHistory, color: Theme.success, label: "Charge %")], maxValue: 100, capacity: MonitorStore.historyLength, format: { String(format: "%.0f%%", $0) }, height: 130)
                }
                if !store.batteryTempHistory.isEmpty {
                    Card("Temperature · live") {
                        VStack(alignment: .leading, spacing: 8) {
                            LiveChart(series: [.init(values: store.batteryTempHistory, color: Theme.warning, label: "°C")], capacity: MonitorStore.historyLength, format: { String(format: "%.1f °C", $0) }, height: 110)
                            MonitorStatsLine(values: store.batteryTempHistory, format: { String(format: "%.1f °C", $0) })
                        }
                    }
                }
                Card("Capacity") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let design = b.designCapacity, let maxCap = b.maxCapacity {
                            BarRow(label: "Full charge capacity", value: Double(maxCap), total: Double(max(design, maxCap)), valueText: "\(Format.count(maxCap)) mAh", tint: Theme.success)
                            BarRow(label: "Design capacity", value: Double(design), total: Double(max(design, maxCap)), valueText: "\(Format.count(design)) mAh", tint: Theme.info)
                            KeyValueRow(key: "Capacity lost", value: "\(Format.count(max(0, design - maxCap))) mAh")
                        } else {
                            Text("Capacity figures are not reported by this battery.").font(Type.text(12)).foregroundStyle(Theme.muted)
                        }
                        KeyValueRow(key: "Temperature", value: b.temperatureC.map { String(format: "%.1f °C", $0) } ?? "—")
                        KeyValueRow(key: "Power source", value: b.onAC ? "AC adapter" : "Battery")
                        KeyValueRow(key: "Charging", value: b.isCharging ? "Yes" : "No")
                        KeyValueRow(key: "Condition", value: b.condition ?? "—")
                    }
                }
                NavRow(icon: "moon.zzz", title: "What keeps the Mac awake?", subtitle: "Power assertions draining battery", tint: Theme.muted, route: .monitor(.powerAssertions))
                NavRow(icon: "flame", title: "Energy-hungry processes", subtitle: "Top CPU right now", route: .monitor(.topCPU))
            } else {
                EmptyPanel(icon: "powerplug", title: "No battery", message: "This Mac runs on AC power only — there is no internal battery to report.")
                TileGrid {
                    StatTile(label: "Power", value: "AC", icon: "powerplug")
                    StatTile(label: "Uptime", value: Format.duration(s.uptime))
                    StatTile(label: "Thermal", value: s.thermalTitle, tint: MonitorFmt.thermalTint(s.thermalState))
                }
                NavRow(icon: "moon.zzz", title: "Sleep blockers", subtitle: "Power assertions", tint: Theme.muted, route: .monitor(.powerAssertions))
            }
        }
    }
}

// MARK: - Thermal & uptime

struct MonitorThermalScreen: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var store = MonitorStore.shared

    var body: some View {
        let s = monitor.latest
        let boot = Date().addingTimeInterval(-s.uptime)
        ScreenScaffold("Thermal & Uptime", subtitle: "ProcessInfo thermal state, pmset thermal report and uptime") {
            TileGrid {
                StatTile(label: "Thermal state", value: s.thermalTitle, tint: MonitorFmt.thermalTint(s.thermalState), history: store.thermalHistory, icon: "thermometer.medium")
                StatTile(label: "Uptime", value: Format.duration(s.uptime), detail: "since \(Format.date(boot))", icon: "clock")
                StatTile(label: "Load 1m", value: MonitorFmt.load(s.loadAverage.first ?? 0), history: monitor.loadHistory)
                StatTile(label: "CPU", value: MonitorFmt.cpu(s.cpu.total), tint: Theme.accent, history: monitor.cpuHistory)
                if let temp = s.battery?.temperatureC {
                    StatTile(label: "Battery temp", value: String(format: "%.1f °C", temp), history: store.batteryTempHistory)
                }
            }
            Card("Thermal state history", trailing: "0 nominal · 1 fair · 2 serious · 3 critical") {
                LiveChart(series: [.init(values: store.thermalHistory, color: MonitorFmt.thermalTint(s.thermalState), label: "State")], maxValue: 3, capacity: MonitorStore.historyLength, format: { String(format: "%.0f", $0) }, height: 110)
            }
            Card("CPU vs load · live") {
                LiveChart(series: [
                    .init(values: monitor.cpuHistory, color: Theme.accent, label: "CPU"),
                    .init(values: monitor.loadHistory.map { $0 / Double(max(1, s.cpu.cores.count)) }, color: Theme.info, label: "Load / core", fill: false),
                ], maxValue: 1, format: { MonitorFmt.cpu($0) }, height: 140)
            }
            Card("pmset -g therm") {
                VStack(alignment: .leading, spacing: 6) {
                    RefreshLine(state: store.thermalReportState) { Task { await store.loadThermalReport(force: true) } }
                    if let report = store.thermalReport {
                        Text(report.output.isEmpty ? "(no thermal warnings recorded)" : report.output)
                            .font(Type.mono(10)).foregroundStyle(Theme.ink).textSelection(.enabled)
                    }
                }
            }
            Card("Uptime") {
                VStack(spacing: 2) {
                    KeyValueRow(key: "Booted", value: Format.date(boot))
                    KeyValueRow(key: "Uptime", value: Format.duration(s.uptime))
                    KeyValueRow(key: "Seconds", value: CountFormat.string(Int(s.uptime)))
                    KeyValueRow(key: "Processes", value: Format.count(s.processCount))
                }
            }
            NavRow(icon: "flame", title: "What is heating the Mac?", subtitle: "Top CPU processes", route: .monitor(.topCPU))
        }
        .task { await store.loadThermalReport() }
    }
}

// MARK: - Sleep blockers

struct MonitorAssertionsScreen: View {
    @ObservedObject private var store = MonitorStore.shared
    @State private var showRaw = false

    var body: some View {
        let report = store.assertions
        let active = report.systemWide.filter { $0.value > 0 }
        ScreenScaffold("Sleep Blockers", subtitle: "Power assertions from pmset -g assertions", actions: {
            RefreshLine(state: store.assertionsState) { Task { await store.loadAssertions(force: true) } }
        }) {
            TileGrid {
                StatTile(label: "Active types", value: "\(active.count)", detail: "of \(report.systemWide.count) assertion types", tint: active.isEmpty ? Theme.success : Theme.warning, icon: "moon.zzz")
                StatTile(label: "Owners", value: "\(report.owners.count)", detail: "\(Set(report.owners.map(\.pid)).count) processes")
                StatTile(label: "Blocks sleep", value: active.contains { $0.name.contains("SystemSleep") } ? "Yes" : "No", tint: active.contains { $0.name.contains("SystemSleep") } ? Theme.warning : Theme.success)
                StatTile(label: "Blocks display sleep", value: active.contains { $0.name.contains("DisplaySleep") } ? "Yes" : "No")
            }
            switch store.assertionsState {
            case .loading(let text) where report.raw.isEmpty:
                LoadingPanel(text: text)
            case .failed(let message):
                ErrorPanel(message: message) { Task { await store.loadAssertions(force: true) } }
            default:
                Card("System-wide") {
                    VStack(spacing: 2) {
                        ForEach(report.systemWide, id: \.name) { item in
                            KeyValueRow(key: item.name, value: item.value > 0 ? "active (\(item.value))" : "0", mono: true)
                        }
                    }
                }
                SectionHeader(title: "By process", detail: "tap to inspect or quit")
                if report.owners.isEmpty {
                    EmptyPanel(icon: "checkmark.circle", title: "Nothing is holding an assertion")
                } else {
                    VStack(spacing: 8) {
                        ForEach(report.owners) { owner in
                            NavRow(icon: owner.type.contains("Display") ? "display" : "moon.zzz", title: "\(owner.process) · \(owner.type)", subtitle: owner.name.isEmpty ? "pid \(owner.pid)" : "\(owner.name) · pid \(owner.pid)", value: owner.age, tint: Theme.warning, route: .monitor(.processDetail(Int(owner.pid))))
                        }
                    }
                }
                Toggle("Show raw pmset output", isOn: $showRaw).toggleStyle(EditorialToggleStyle())
                if showRaw {
                    Card {
                        Text(report.raw).font(Type.mono(10)).foregroundStyle(Theme.ink).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .task { await store.loadAssertions() }
    }
}

// MARK: - System info

struct MonitorSystemInfoScreen: View {
    @ObservedObject private var store = MonitorStore.shared
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        ScreenScaffold("System Info", subtitle: "sysctl and system_profiler", actions: {
            RefreshLine(state: store.systemInfoState) { Task { await store.loadSystemInfo(force: true) } }
        }) {
            if let info = store.systemInfo {
                TileGrid {
                    StatTile(label: "Model", value: info.marketingName ?? info.model, detail: info.model, icon: "desktopcomputer")
                    StatTile(label: "Chip", value: info.chip, detail: info.architecture, icon: "cpu")
                    StatTile(label: "Memory", value: Format.bytes(info.memory), icon: "memorychip")
                    StatTile(label: "Cores", value: "\(info.physicalCores)", detail: "\(info.logicalCores) logical", icon: "square.grid.3x3")
                    StatTile(label: "macOS", value: info.osVersion, icon: "apple.logo")
                    StatTile(label: "Uptime", value: Format.duration(monitor.latest.uptime), detail: info.bootTime.map { "booted \(Format.date($0))" }, icon: "clock")
                }
                Card("Hardware") {
                    VStack(spacing: 2) {
                        KeyValueRow(key: "Model name", value: info.marketingName ?? "—")
                        KeyValueRow(key: "Model identifier", value: info.model, mono: true)
                        KeyValueRow(key: "Model number", value: info.modelNumber ?? "—", mono: true)
                        KeyValueRow(key: "Chip", value: info.chip)
                        KeyValueRow(key: "Architecture", value: info.architecture)
                        KeyValueRow(key: "Physical cores", value: "\(info.physicalCores)")
                        KeyValueRow(key: "Logical cores", value: "\(info.logicalCores)")
                        if let p = info.performanceCores { KeyValueRow(key: "Performance cores", value: "\(p)") }
                        if let e = info.efficiencyCores { KeyValueRow(key: "Efficiency cores", value: "\(e)") }
                        KeyValueRow(key: "Memory", value: "\(Format.bytes(info.memory)) (\(CountFormat.string(info.memory)) B)")
                        KeyValueRow(key: "Page size", value: "\(Format.count(info.pageSize)) bytes")
                        KeyValueRow(key: "Firmware", value: info.firmware ?? "—", mono: true)
                    }
                }
                Card("Software") {
                    VStack(spacing: 2) {
                        KeyValueRow(key: "macOS", value: info.osVersion)
                        KeyValueRow(key: "Kernel", value: info.kernel ?? "—", mono: true)
                        KeyValueRow(key: "Hostname", value: info.hostname, mono: true)
                        KeyValueRow(key: "Booted", value: Format.date(info.bootTime))
                        KeyValueRow(key: "System Integrity Protection", value: info.sip ?? "—")
                        KeyValueRow(key: "Secure virtual memory", value: info.secureVM ?? "—")
                        KeyValueRow(key: "User", value: NSUserName())
                    }
                }
                HStack(spacing: 10) {
                    Button("Copy summary") {
                        let text = """
                        \(info.marketingName ?? info.model) (\(info.model))
                        \(info.chip) · \(info.physicalCores) cores · \(Format.bytes(info.memory))
                        \(info.osVersion) · \(info.kernel ?? "")
                        """
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        ToastCenter.shared.show("System summary copied")
                    }
                    .buttonStyle(EditorialButtonStyle(kind: .secondary))
                    Button("Open System Information") { EngineActions.open("/System/Applications/Utilities/System Information.app") }
                        .buttonStyle(EditorialButtonStyle(kind: .ghost))
                }
                VStack(spacing: 8) {
                    NavRow(icon: "square.grid.3x3", title: "CPU cores", value: "\(info.logicalCores)", route: .monitor(.cores))
                    NavRow(icon: "externaldrive", title: "Volumes", tint: Theme.warning, route: .monitor(.volumes))
                    NavRow(icon: "network", title: "Network interfaces", tint: Theme.success, route: .monitor(.networkOverview))
                    NavRow(icon: "battery.75", title: "Battery", tint: Theme.success, route: .monitor(.battery))
                }
            } else if case .failed(let message) = store.systemInfoState {
                ErrorPanel(message: message) { Task { await store.loadSystemInfo(force: true) } }
            } else {
                LoadingPanel(text: "Reading hardware and software profile…", detail: "system_profiler can take a few seconds")
            }
        }
        .task { await store.loadSystemInfo() }
    }
}

// MARK: - Activity

struct MonitorActivityScreen: View {
    @ObservedObject private var log = ActivityLog.shared
    @State private var query = ""
    @State private var module = "All"

    var body: some View {
        let modules = ["All"] + Array(Set(log.entries.map(\.module))).sorted()
        let filtered = log.entries.filter {
            (module == "All" || $0.module == module)
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query))
        }
        let byModule = Dictionary(grouping: log.entries, by: \.module).mapValues { $0.reduce(Int64(0)) { $0 + $1.bytes } }.sorted { $0.value > $1.value }
        ScreenScaffold("Activity", subtitle: "Every cleanup and action MacLean performed") {
            TileGrid {
                StatTile(label: "Actions", value: Format.count(log.entries.count), icon: "clock.arrow.circlepath")
                StatTile(label: "Freed total", value: Format.bytes(log.totalFreed), tint: Theme.success)
                StatTile(label: "Items", value: Format.count(log.entries.reduce(0) { $0 + $1.items }))
                StatTile(label: "Failures", value: Format.count(log.entries.reduce(0) { $0 + $1.failures }), tint: Theme.danger)
                StatTile(label: "Last 7 days", value: Format.bytes(log.entries.filter { $0.date > Date().addingTimeInterval(-7 * 86_400) }.reduce(0) { $0 + $1.bytes }))
            }
            if !byModule.isEmpty {
                Card("Freed by module") {
                    VStack(spacing: 8) {
                        ForEach(byModule, id: \.key) { item in
                            BarRow(label: item.key, value: Double(item.value), total: Double(max(1, byModule.first?.value ?? 1)), valueText: Format.bytes(item.value), tint: Theme.success) {
                                module = item.key
                            }
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                SearchField(text: $query, prompt: "Filter activity")
                EditorialPicker(label: "Module", selection: $module, options: modules, title: { $0 })
                Spacer()
                ConfirmButton(title: "Clear History", message: "Removes all \(log.entries.count) activity records. Files already removed are not affected.", kind: .destructive, disabled: log.entries.isEmpty) {
                    log.clear()
                }
            }
            if log.entries.isEmpty {
                EmptyPanel(icon: "clock", title: "No activity yet", message: "Cleanups, quits and ejects show up here.", actionTitle: "Run Smart Scan") { Navigator.shared.go(.cleanup) }
            } else if filtered.isEmpty {
                EmptyPanel(icon: "magnifyingglass", title: "No matching activity")
            } else {
                Card(trailing: "\(filtered.count) shown") {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filtered) { entry in
                            VStack(alignment: .leading, spacing: 1) {
                                MonitorActivityRow(entry: entry)
                                Text(Format.date(entry.date)).font(Type.mono(9)).foregroundStyle(Theme.faint)
                            }
                            Hairline()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Sampling

struct MonitorSamplingScreen: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var store = MonitorStore.shared

    var body: some View {
        let window = Double(SystemMonitor.historyLength) * monitor.intervalSeconds
        ScreenScaffold("Sampling", subtitle: "How often live metrics are read") {
            TileGrid {
                StatTile(label: "Interval", value: String(format: "%g s", monitor.intervalSeconds), icon: "timer")
                StatTile(label: "State", value: store.paused ? "Paused" : "Live", tint: store.paused ? Theme.warning : Theme.success)
                StatTile(label: "History window", value: Format.duration(window), detail: "\(SystemMonitor.historyLength) samples")
                StatTile(label: "Samples taken", value: Format.count(store.sampleCount), detail: "since \(Format.date(store.startedAt))")
            }
            Card("Interval") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ForEach([0.5, 1.0, 2.0, 5.0], id: \.self) { value in
                            Button(String(format: "%g s", value)) { monitor.intervalSeconds = value }
                                .buttonStyle(EditorialButtonStyle(kind: monitor.intervalSeconds == value ? .primary : .secondary))
                        }
                    }
                    Text("Faster sampling makes graphs smoother but costs a little CPU. Processes are re-read every third sample with ps.")
                        .font(Type.text(11)).foregroundStyle(Theme.muted)
                }
            }
            Card("Live sampling") {
                HStack(spacing: 12) {
                    Button(store.paused ? "Resume Sampling" : "Pause Sampling") { store.setPaused(!store.paused) }
                        .buttonStyle(EditorialButtonStyle(kind: store.paused ? .primary : .secondary))
                    Button("Reset Session Peaks") { store.resetPeaks() }
                        .buttonStyle(EditorialButtonStyle(kind: .ghost))
                    Spacer()
                    Text(store.paused ? "Graphs are frozen" : "Updating").font(Type.text(11)).foregroundStyle(Theme.muted)
                }
            }
            Card("Session peaks") {
                VStack(spacing: 2) {
                    KeyValueRow(key: "CPU", value: MonitorFmt.cpu1(store.peakCPU))
                    KeyValueRow(key: "Memory used", value: Format.bytes(store.peakMemory))
                    KeyValueRow(key: "Download", value: Format.rate(store.peakRx))
                    KeyValueRow(key: "Upload", value: Format.rate(store.peakTx))
                }
            }
            Card("Sampler cost") {
                LiveChart(series: [.init(values: monitor.cpuHistory, color: Theme.accent, label: "System CPU")], maxValue: 1, format: { MonitorFmt.cpu($0) }, height: 90)
            }
        }
    }
}
