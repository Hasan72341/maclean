import AppKit
import MacLeanCore
import SwiftUI

enum MonitorProcessSort: String, CaseIterable, Hashable {
    case cpu = "CPU"
    case memory = "Memory"
    case name = "Name"
    case pid = "PID"

    func sorted(_ list: [ProcessSample]) -> [ProcessSample] {
        switch self {
        case .cpu: return list.sorted { ($0.cpu, $0.memory) > ($1.cpu, $1.memory) }
        case .memory: return list.sorted { $0.memory > $1.memory }
        case .name: return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .pid: return list.sorted { $0.pid < $1.pid }
        }
    }
}

private func monitorIsProtected(_ pid: Int32) -> Bool {
    pid <= 1 || pid == getpid()
}

/// Shared selection + quit footer for process lists.
struct MonitorProcessSelectionFooter: View {
    let visible: [ProcessSample]
    @Binding var selection: Set<Int32>
    @Binding var force: Bool
    @ObservedObject private var store = MonitorStore.shared

    var body: some View {
        let chosen = visible.filter { selection.contains($0.pid) && !monitorIsProtected($0.pid) }
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Force quit (SIGKILL — unsaved work is lost)", isOn: $force).toggleStyle(EditorialToggleStyle())
            SelectionBar(
                selectedCount: chosen.count,
                totalCount: visible.count,
                selectedBytes: chosen.reduce(0) { $0 + $1.memory },
                actionTitle: force ? "Force Quit Selected" : "Quit Selected",
                confirmMessage: force
                    ? "Sends SIGKILL to \(chosen.count) process(es): \(chosen.prefix(6).map(\.name).joined(separator: ", ")). They stop immediately and unsaved work is lost. launchd, the kernel and MacLean are always skipped."
                    : "Sends SIGTERM to \(chosen.count) process(es): \(chosen.prefix(6).map(\.name).joined(separator: ", ")), asking them to exit. launchd, the kernel and MacLean are always skipped.",
                busy: store.actionBusy,
                onSelectAll: { selection = Set(visible.filter { !monitorIsProtected($0.pid) }.map(\.pid)) },
                onSelectNone: { selection = [] }
            ) {
                let pids = chosen.map(\.pid)
                let names = Dictionary(chosen.map { ($0.pid, $0.name) }, uniquingKeysWith: { a, _ in a })
                let memory = Dictionary(chosen.map { ($0.pid, $0.memory) }, uniquingKeysWith: { a, _ in a })
                Task {
                    await store.signal(pids, force: force, names: names, memory: memory)
                    selection = []
                }
            }
            if !store.lastFailures.isEmpty {
                FailureList(failures: store.lastFailures)
                Text("Processes owned by root or other users need administrator rights — open one and use “Quit as Administrator”.")
                    .font(Type.text(11)).foregroundStyle(Theme.muted)
            }
        }
    }
}

struct MonitorProcessRow: View {
    let process: ProcessSample
    @Binding var selected: Bool
    var highlightCPU: Bool = true
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        CheckRow(
            isOn: monitorIsProtected(process.pid) ? .constant(false) : $selected,
            title: process.name,
            subtitle: "pid \(process.pid) · \(process.user) · \(MonitorFmt.psCPU(process.cpu)) CPU",
            value: highlightCPU ? "\(MonitorFmt.psCPU(process.cpu))  \(Format.bytes(process.memory))" : Format.bytes(process.memory),
            badge: monitorIsProtected(process.pid) ? "protected" : (process.user == "root" ? "root" : nil),
            badgeTint: monitorIsProtected(process.pid) ? Theme.muted : Theme.warning,
            onOpen: { nav.push(.monitor(.processDetail(Int(process.pid)))) },
            onReveal: MonitorProbe.executablePath(process.pid).map { path in { EngineActions.reveal(path) } }
        )
    }
}

// MARK: - Top CPU / memory

struct MonitorTopProcessesScreen: View {
    enum Mode { case cpu, memory }
    let mode: Mode
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var store = MonitorStore.shared
    @State private var selection: Set<Int32> = []
    @State private var force = false
    @State private var limit = 25

    var body: some View {
        let all = monitor.processes
        let sorted = mode == .cpu ? MonitorProcessSort.cpu.sorted(all) : MonitorProcessSort.memory.sorted(all)
        let top = Array(sorted.prefix(limit))
        let totalCPU = all.reduce(0) { $0 + $1.cpu }
        let totalMem = all.reduce(0) { $0 + $1.memory }
        ScreenScaffold(mode == .cpu ? "Top CPU" : "Top Memory", subtitle: "Live from ps · refreshed every 3 samples") {
            TileGrid {
                if mode == .cpu {
                    StatTile(label: "System CPU", value: MonitorFmt.cpu(monitor.latest.cpu.total), tint: Theme.accent, history: monitor.cpuHistory, icon: "cpu")
                    StatTile(label: "Sum of processes", value: MonitorFmt.psCPU(totalCPU), detail: "100% = one full core")
                    StatTile(label: "Busiest", value: top.first.map { MonitorFmt.psCPU($0.cpu) } ?? "—", detail: top.first?.name, tint: Theme.danger)
                    StatTile(label: "Above 10%", value: "\(all.filter { $0.cpu > 10 }.count)", tint: Theme.warning)
                } else {
                    StatTile(label: "Used memory", value: Format.bytes(monitor.latest.memory.used), tint: Theme.info, history: monitor.memoryHistory, icon: "memorychip")
                    StatTile(label: "Sum of RSS", value: Format.bytes(totalMem), detail: "shared pages counted per process")
                    StatTile(label: "Largest", value: top.first.map { Format.bytes($0.memory) } ?? "—", detail: top.first?.name, tint: Theme.danger)
                    StatTile(label: "Over 500 MB", value: "\(all.filter { $0.memory > 500_000_000 }.count)", tint: Theme.warning)
                }
            }
            Card(mode == .cpu ? "Top 10 share" : "Top 10 resident size") {
                VStack(spacing: 8) {
                    let peak = mode == .cpu ? max(100, top.first?.cpu ?? 0) : Double(top.first?.memory ?? 1)
                    ForEach(Array(top.prefix(10))) { process in
                        MonitorLink(route: .processDetail(Int(process.pid))) {
                            BarRow(
                                label: "\(process.name)  ·  \(process.pid)",
                                value: mode == .cpu ? process.cpu : Double(process.memory),
                                total: peak,
                                valueText: mode == .cpu ? MonitorFmt.psCPU(process.cpu) : Format.bytes(process.memory),
                                tint: mode == .cpu ? Theme.accent : Theme.info
                            )
                            .padding(.trailing, 24)
                        }
                    }
                }
            }
            if all.isEmpty {
                LoadingPanel(text: "Sampling processes…")
            } else {
                HStack {
                    SectionHeader(title: "Top \(top.count)", detail: "of \(Format.count(all.count)) processes")
                    Spacer()
                    EditorialPicker(label: "Show", selection: $limit, options: [10, 25, 50, 100], title: { "\($0)" })
                }
                VStack(spacing: 0) {
                    ForEach(top) { process in
                        MonitorProcessRow(process: process, selected: binding(process.pid), highlightCPU: mode == .cpu)
                    }
                }
                MonitorProcessSelectionFooter(visible: top, selection: $selection, force: $force)
                NavRow(icon: "list.bullet.rectangle", title: "All processes", subtitle: "search and sort every process", value: Format.count(all.count), route: .monitor(.processList))
            }
        }
        .task { await SystemMonitor.shared.refreshProcesses() }
    }

    private func binding(_ pid: Int32) -> Binding<Bool> {
        Binding(get: { selection.contains(pid) }, set: { if $0 { selection.insert(pid) } else { selection.remove(pid) } })
    }
}

// MARK: - All processes

struct MonitorProcessListScreen: View {
    let userFilter: String?
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var store = MonitorStore.shared
    @State private var query = ""
    @State private var sort: MonitorProcessSort = .cpu
    @State private var selection: Set<Int32> = []
    @State private var force = false
    @State private var frozen: [ProcessSample]?

    var body: some View {
        let source = frozen ?? monitor.processes
        let base = userFilter.map { user in source.filter { $0.user == user } } ?? source
        let filtered = query.isEmpty ? base : base.filter {
            $0.name.localizedCaseInsensitiveContains(query) || String($0.pid) == query || $0.user.localizedCaseInsensitiveContains(query)
        }
        let visible = sort.sorted(filtered)
        ScreenScaffold(userFilter.map { "Processes · \($0)" } ?? "Processes", subtitle: frozen == nil ? "Live list · \(Format.count(source.count)) running" : "Frozen snapshot · live updates paused for this list") {
            TileGrid {
                StatTile(label: "Shown", value: Format.count(visible.count), detail: "of \(Format.count(base.count))", icon: "list.bullet")
                StatTile(label: "CPU total", value: MonitorFmt.psCPU(visible.reduce(0) { $0 + $1.cpu }), tint: Theme.accent)
                StatTile(label: "Memory total", value: Format.bytes(visible.reduce(0) { $0 + $1.memory }), tint: Theme.info)
                StatTile(label: "Users", value: "\(Set(visible.map(\.user)).count)")
            }
            HStack(spacing: 12) {
                SearchField(text: $query, prompt: "Name, pid or user")
                EditorialPicker(label: "Sort", selection: $sort, options: MonitorProcessSort.allCases, title: { $0.rawValue })
                Button(frozen == nil ? "Freeze" : "Go Live") {
                    frozen = frozen == nil ? monitor.processes : nil
                }
                .buttonStyle(EditorialButtonStyle(kind: .secondary))
                Button("Refresh") { Task { await SystemMonitor.shared.refreshProcesses(); if frozen != nil { frozen = monitor.processes } } }
                    .buttonStyle(EditorialButtonStyle(kind: .ghost))
            }
            if source.isEmpty {
                LoadingPanel(text: "Sampling processes…")
            } else if visible.isEmpty {
                EmptyPanel(icon: "magnifyingglass", title: "No matching processes", message: "Nothing matches “\(query)”.", actionTitle: "Clear search") { query = "" }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { process in
                        MonitorProcessRow(process: process, selected: binding(process.pid))
                    }
                }
                MonitorProcessSelectionFooter(visible: visible, selection: $selection, force: $force)
            }
        }
        .task { await SystemMonitor.shared.refreshProcesses() }
    }

    private func binding(_ pid: Int32) -> Binding<Bool> {
        Binding(get: { selection.contains(pid) }, set: { if $0 { selection.insert(pid) } else { selection.remove(pid) } })
    }
}

// MARK: - By user

struct MonitorProcessUsersScreen: View {
    @ObservedObject private var monitor = SystemMonitor.shared

    private struct Group: Identifiable {
        let user: String
        let count: Int
        let cpu: Double
        let memory: Int64
        var id: String { user }
    }

    var body: some View {
        let groups = Dictionary(grouping: monitor.processes, by: \.user)
            .map { Group(user: $0.key, count: $0.value.count, cpu: $0.value.reduce(0) { $0 + $1.cpu }, memory: $0.value.reduce(0) { $0 + $1.memory }) }
            .sorted { $0.memory > $1.memory }
        let peak = Double(groups.first?.memory ?? 1)
        ScreenScaffold("Processes by User", subtitle: "\(groups.count) accounts own \(Format.count(monitor.processes.count)) processes") {
            TileGrid {
                StatTile(label: "Accounts", value: "\(groups.count)", icon: "person.2")
                StatTile(label: "Yours", value: Format.count(groups.first { $0.user == NSUserName() }?.count ?? 0), detail: NSUserName(), tint: Theme.accent)
                StatTile(label: "root", value: Format.count(groups.first { $0.user == "root" }?.count ?? 0), tint: Theme.warning)
                StatTile(label: "System services", value: Format.count(groups.filter { $0.user.hasPrefix("_") }.reduce(0) { $0 + $1.count }), detail: "underscore accounts")
            }
            if groups.isEmpty {
                LoadingPanel(text: "Sampling processes…")
            } else {
                Card("Memory by account") {
                    VStack(spacing: 8) {
                        ForEach(groups.prefix(12)) { group in
                            BarRow(label: "\(group.user) · \(group.count) proc", value: Double(group.memory), total: peak, valueText: "\(Format.bytes(group.memory)) · \(MonitorFmt.psCPU(group.cpu))", tint: group.user == NSUserName() ? Theme.accent : Theme.info)
                        }
                    }
                }
                VStack(spacing: 8) {
                    ForEach(groups) { group in
                        NavRow(icon: group.user == "root" ? "lock.shield" : "person", title: group.user, subtitle: "\(group.count) processes · \(MonitorFmt.psCPU(group.cpu)) CPU", value: Format.bytes(group.memory), tint: group.user == NSUserName() ? Theme.accent : Theme.muted, route: .monitor(.userProcesses(group.user)))
                    }
                }
            }
        }
    }
}

// MARK: - Process detail

struct MonitorProcessDetailScreen: View {
    let pid: Int32
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var store = MonitorStore.shared
    @State private var permissionDenied = false

    var body: some View {
        let sample = monitor.processes.first { $0.pid == pid }
        let details = store.details[pid]
        let app = NSRunningApplication(processIdentifier: pid)
        let name = app?.localizedName ?? sample?.name ?? details?.name ?? "pid \(pid)"
        let cpuHistory = store.processCPU[pid] ?? []
        let memHistory = store.processMemory[pid] ?? []
        let alive = sample != nil || (details?.alive ?? true)
        ScreenScaffold(name, subtitle: alive ? "pid \(pid)\(details?.path.map { " · \($0)" } ?? "")" : "pid \(pid) · no longer running") {
            HStack(spacing: 14) {
                if let icon = app?.icon {
                    Image(nsImage: icon).resizable().frame(width: 48, height: 48)
                } else {
                    Image(systemName: "gearshape.2").font(.system(size: 30)).foregroundStyle(Theme.muted).frame(width: 48, height: 48)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(Type.display(22, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(app?.bundleIdentifier ?? (details?.path ?? "—")).font(Type.mono(10)).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
                Spacer()
                if !alive { RiskBadge(text: "exited", tint: Theme.muted) }
                if monitorIsProtected(pid) { RiskBadge(text: "protected", tint: Theme.muted) }
            }
            TileGrid {
                StatTile(label: "CPU", value: sample.map { MonitorFmt.psCPU($0.cpu) } ?? "—", detail: "avg \(MonitorFmt.psCPU(MonitorFmt.average(cpuHistory)))", tint: Theme.accent, history: cpuHistory, icon: "cpu")
                StatTile(label: "Memory (RSS)", value: sample.map { Format.bytes($0.memory) } ?? details?.residentBytes.map { Format.bytes($0) } ?? "—", detail: "peak \(MonitorFmt.bytes(memHistory.max() ?? 0))", tint: Theme.info, history: memHistory, icon: "memorychip")
                StatTile(label: "Threads", value: details?.threads.map { Format.count($0) } ?? "—", detail: details?.threads == nil ? "needs same-user access" : nil)
                StatTile(label: "Running for", value: details?.startDate.map { Format.duration(Date().timeIntervalSince($0)) } ?? "—", detail: details?.startDate.map { Format.date($0) })
                StatTile(label: "User", value: sample?.user ?? details?.uid.flatMap { MonitorProbe.userName($0) } ?? "—", detail: details?.uid.map { "uid \($0)" })
                StatTile(label: "Virtual", value: details?.virtualBytes.map { Format.bytes($0) } ?? "—")
            }
            Card("CPU · this process", trailing: "\(cpuHistory.count) samples") {
                VStack(alignment: .leading, spacing: 8) {
                    LiveChart(series: [.init(values: cpuHistory, color: Theme.accent, label: "CPU")], maxValue: max(100, (cpuHistory.max() ?? 0) * 1.1), capacity: MonitorStore.historyLength, format: { MonitorFmt.psCPU($0) }, height: 140)
                    MonitorStatsLine(values: cpuHistory, format: { MonitorFmt.psCPU($0) })
                }
            }
            Card("Memory · this process") {
                VStack(alignment: .leading, spacing: 8) {
                    LiveChart(series: [.init(values: memHistory, color: Theme.info, label: "RSS")], capacity: MonitorStore.historyLength, format: { MonitorFmt.bytes($0) }, height: 140)
                    MonitorStatsLine(values: memHistory, format: { MonitorFmt.bytes($0) })
                }
            }
            Card("Details") {
                VStack(alignment: .leading, spacing: 2) {
                    KeyValueRow(key: "PID", value: "\(pid)", mono: true)
                    KeyValueRow(key: "Executable", value: details?.path ?? "unavailable (owned by another user)", mono: true)
                    KeyValueRow(key: "Bundle", value: app?.bundleURL?.path ?? "—", mono: true)
                    KeyValueRow(key: "Started", value: Format.date(details?.startDate))
                    KeyValueRow(key: "Nice", value: details?.nice.map { "\($0)" } ?? "—")
                    KeyValueRow(key: "Active app", value: app.map { $0.isActive ? "yes" : ($0.isHidden ? "hidden" : "background") } ?? "not a GUI app")
                    if let path = details?.path {
                        HStack {
                            Button("Reveal in Finder") { EngineActions.reveal(app?.bundleURL?.path ?? path) }
                                .buttonStyle(EditorialButtonStyle(kind: .inline))
                            Button("Copy path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(path, forType: .string)
                            }
                            .buttonStyle(EditorialButtonStyle(kind: .inline))
                        }
                        .padding(.top, 6)
                    }
                }
            }
            treeSection(details)
            actions(name: name, sample: sample, alive: alive)
            if let output = store.lastCommand, output.command.contains("kill") {
                MonitorCommandCard(output: output)
            }
        }
        .task(id: pid) {
            while !Task.isCancelled {
                await store.refreshDetails(pid)
                await store.loadParents()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    @ViewBuilder
    private func treeSection(_ details: MonitorProcessDetails?) -> some View {
        let children = store.children(of: pid)
        let names = Dictionary(monitor.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Process tree", detail: "\(children.count) children")
            if let ppid = details?.ppid, ppid > 0 {
                NavRow(icon: "arrow.up.circle", title: "Parent: \(names[ppid]?.name ?? "pid \(ppid)")", subtitle: "pid \(ppid)", value: names[ppid].map { Format.bytes($0.memory) }, tint: Theme.muted, route: .monitor(.processDetail(Int(ppid))))
            }
            ForEach(children.prefix(30), id: \.self) { child in
                NavRow(icon: "arrow.turn.down.right", title: names[child]?.name ?? "pid \(child)", subtitle: "pid \(child)\(names[child].map { " · \(MonitorFmt.psCPU($0.cpu)) CPU" } ?? "")", value: names[child].map { Format.bytes($0.memory) }, tint: Theme.info, route: .monitor(.processDetail(Int(child))))
            }
            if children.count > 30 {
                Text("+\(children.count - 30) more children").font(Type.text(11)).foregroundStyle(Theme.muted)
            }
        }
    }

    @ViewBuilder
    private func actions(name: String, sample: ProcessSample?, alive: Bool) -> some View {
        Card("Actions") {
            VStack(alignment: .leading, spacing: 10) {
                if monitorIsProtected(pid) {
                    Text(pid == getpid() ? "This is MacLean itself — use Quit from the menu instead." : "pid \(pid) is a core system process and cannot be signalled.")
                        .font(Type.text(12)).foregroundStyle(Theme.muted)
                } else if !alive {
                    Text("The process has exited.").font(Type.text(12)).foregroundStyle(Theme.muted)
                } else {
                    HStack(spacing: 10) {
                        ConfirmButton(title: "Quit", message: "Send SIGTERM to \(name) (pid \(pid)) asking it to exit cleanly.", kind: .secondary, disabled: store.actionBusy) {
                            run(force: false, name: name, sample: sample)
                        }
                        ConfirmButton(title: "Force Quit", message: "Send SIGKILL to \(name) (pid \(pid)). It stops immediately and unsaved work is lost.", kind: .destructive, disabled: store.actionBusy) {
                            run(force: true, name: name, sample: sample)
                        }
                        if store.actionBusy { ProgressView().controlSize(.small) }
                    }
                    if permissionDenied || (sample?.user ?? NSUserName()) != NSUserName() {
                        Text("Owned by \(sample?.user ?? "another user"). Quitting needs administrator rights.")
                            .font(Type.text(11)).foregroundStyle(Theme.warning)
                        HStack(spacing: 10) {
                            ConfirmButton(title: "Quit as Administrator", message: "macOS will ask for your password, then run: kill -15 \(pid)", kind: .secondary, disabled: store.actionBusy) {
                                Task { await store.adminSignal(pid, force: false, name: name) }
                            }
                            ConfirmButton(title: "Force Quit as Administrator", message: "macOS will ask for your password, then run: kill -9 \(pid). Killing system daemons can destabilise macOS until they relaunch.", kind: .destructive, disabled: store.actionBusy) {
                                Task { await store.adminSignal(pid, force: true, name: name) }
                            }
                        }
                        MonitorCopyCommand(command: "sudo kill -15 \(pid)")
                    }
                    if !store.lastFailures.isEmpty {
                        FailureList(failures: store.lastFailures)
                    }
                }
            }
        }
    }

    private func run(force: Bool, name: String, sample: ProcessSample?) {
        Task {
            await store.signal([pid], force: force, names: [pid: name], memory: [pid: sample?.memory ?? 0])
            permissionDenied = store.lastFailures.contains { $0.reason.contains("Permission") }
            await store.refreshDetails(pid)
        }
    }
}
