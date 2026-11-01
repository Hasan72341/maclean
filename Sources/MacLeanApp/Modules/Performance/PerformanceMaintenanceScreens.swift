import AppKit
import MacLeanCore
import SwiftUI

struct PerformanceTaskGrid: View {
    @ObservedObject private var store = PerformanceStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        TileGrid(minWidth: 210) {
            ForEach(PerformanceTask.allCases) { task in
                Button { nav.push(.performance(task.route)) } label: { tile(task) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func tile(_ task: PerformanceTask) -> some View {
        let last = store.lastRun(task)
        let running = store.runs[task]?.running == true
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: task.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.12)))
                Spacer()
                if running {
                    ProgressView().controlSize(.small)
                } else if !task.isAvailable {
                    RiskBadge(text: "unavailable", tint: Theme.warning)
                } else if task.needsAdmin {
                    RiskBadge(text: "admin", tint: Theme.info)
                }
            }
            Text(task.title).font(Type.text(13, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
            Text(task.summary).font(Type.text(11)).foregroundStyle(Theme.muted).lineLimit(2).frame(height: 30, alignment: .top)
            HStack(spacing: 6) {
                Circle().fill(last == nil ? Theme.faint : last!.status == 0 ? Theme.success : Theme.danger).frame(width: 6, height: 6)
                Text(running ? "Running…" : last.map { "Last run \(Format.relative($0.date)) · exit \($0.status)" } ?? "Never run")
                    .font(Type.mono(10)).foregroundStyle(Theme.faint).lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(running ? Theme.accent : Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

struct PerformanceMaintenanceScreen: View {
    @ObservedObject private var store = PerformanceStore.shared

    var body: some View {
        let ran = PerformanceTask.allCases.filter { store.lastRun($0) != nil }
        let failed = PerformanceTask.allCases.filter { (store.lastRun($0)?.status ?? 0) != 0 }
        let running = PerformanceTask.allCases.filter { store.runs[$0]?.running == true }
        ScreenScaffold("Maintenance", subtitle: "macOS housekeeping tasks — each runs the real system tool and shows its output") {
            NavRow(icon: "list.bullet.rectangle", title: "History", value: Format.count(store.history.count), route: .performance(.maintenanceHistory))
                .frame(width: 200)
        } content: {
            TileGrid {
                StatTile(label: "Tasks", value: "\(PerformanceTask.allCases.count)", detail: "\(PerformanceTask.allCases.filter(\.needsAdmin).count) need admin", icon: "wrench.and.screwdriver")
                StatTile(label: "Ever run", value: "\(ran.count)", detail: "of \(PerformanceTask.allCases.count)", icon: "checkmark.circle")
                StatTile(label: "Last failed", value: "\(failed.count)", tint: failed.isEmpty ? Theme.success : Theme.danger, icon: "xmark.octagon")
                StatTile(label: "Running", value: "\(running.count)", tint: running.isEmpty ? Theme.ink : Theme.accent, icon: "play.circle")
                StatTile(label: "Total runs", value: Format.count(store.history.count),
                         detail: store.history.first.map { "latest \(Format.relative($0.date))" }, icon: "clock")
            }
            PerformanceTaskGrid()
        }
    }
}

struct PerformanceTaskScreen: View {
    let task: PerformanceTask
    @ObservedObject private var store = PerformanceStore.shared
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let run = store.runs[task]
        let last = store.lastRun(task)
        let runs = store.history.filter { $0.task == task.rawValue }
        let running = run?.running == true
        ScreenScaffold(task.title, subtitle: task.summary) {
            if running && store.canCancel(task) {
                Button("Stop") { store.cancel(task) }.buttonStyle(EditorialButtonStyle(kind: .destructive))
            }
            ConfirmButton(title: running ? "Running…" : "Run",
                          message: task.details + (task.needsAdmin ? "\n\nmacOS will ask for your administrator password." : ""),
                          disabled: running || !task.isAvailable) {
                store.run(task)
            }
        } content: {
            if !task.isAvailable {
                ErrorPanel(message: "\(task.executable) is not present on this version of macOS, so this task cannot run here.")
            }
            TileGrid {
                StatTile(label: "Risk", value: task.risk, tint: task.risk == "Low" ? Theme.success : Theme.warning, icon: "exclamationmark.shield")
                StatTile(label: "Needs admin", value: task.needsAdmin ? "Yes" : "No", detail: task.needsAdmin ? "password prompt" : "runs as you", icon: "lock")
                StatTile(label: "Last run", value: last.map { Format.relative($0.date) } ?? "Never", detail: last.map { Format.date($0.date) }, icon: "clock")
                StatTile(label: "Last exit", value: last.map { "\($0.status)" } ?? "—",
                         detail: last.map { "took \(PerformanceTaskScreen.elapsed($0.duration))" },
                         tint: last == nil ? Theme.ink : last!.status == 0 ? Theme.success : Theme.danger, icon: "flag.checkered")
                StatTile(label: "Runs", value: Format.count(runs.count),
                         detail: "\(runs.filter { $0.status == 0 }.count) succeeded", icon: "number")
            }

            Card("What it does") {
                Text(task.details).font(Type.text(12)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(task.commandLine).font(Type.mono(11)).foregroundStyle(Theme.accent).textSelection(.enabled).lineLimit(2)
                    Spacer()
                    Button("Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(task.commandLine, forType: .string)
                        ToastCenter.shared.show("Command copied")
                    }
                    .buttonStyle(EditorialButtonStyle(kind: .ghost))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paper))
            }

            extra

            if let run {
                Card(run.running ? "Running" : "Result", trailing: run.admin ? "as administrator" : "as \(NSUserName())") {
                    HStack(spacing: 18) {
                        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("ELAPSED").font(Type.label).foregroundStyle(Theme.muted)
                                Text(PerformanceTaskScreen.elapsed(run.elapsed))
                                    .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .foregroundStyle(run.running ? Theme.accent : Theme.ink)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("EXIT STATUS").font(Type.label).foregroundStyle(Theme.muted)
                            Text(run.status.map { "\($0)" } ?? "—")
                                .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(run.status == nil ? Theme.muted : run.status == 0 ? Theme.success : Theme.danger)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("OUTPUT").font(Type.label).foregroundStyle(Theme.muted)
                            Text("\(Format.count(run.output.split(separator: "\n").count)) lines")
                                .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.ink)
                        }
                        Spacer()
                        if run.running { ProgressView().controlSize(.regular) }
                        if !run.running, let status = run.status {
                            Image(systemName: status == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .font(.system(size: 28)).foregroundStyle(status == 0 ? Theme.success : Theme.danger)
                        }
                    }
                    PerformanceOutputPanel(text: run.output, height: 260)
                    if task == .flushDNS, !run.running, run.status != 0 {
                        HStack {
                            Text("mDNSResponder could not be restarted without root.").font(Type.text(11)).foregroundStyle(Theme.muted)
                            Button("Retry as administrator") { store.run(task, forceAdmin: true) }
                                .buttonStyle(EditorialButtonStyle(kind: .secondary))
                        }
                    }
                    if run.status == -128 || run.output.contains("User canceled") || run.output.contains("(-128)") {
                        Text("The administrator prompt was cancelled.").font(Type.text(11)).foregroundStyle(Theme.warning)
                    }
                }
            } else {
                EmptyPanel(icon: task.icon, title: "Not run in this session",
                           message: last == nil ? "Press Run to start. Output appears here as it is produced." : "Last run \(Format.date(last?.date)). Its saved output is below.",
                           actionTitle: nil)
                if let last, !last.outputTail.isEmpty {
                    Card("Saved output", trailing: Format.date(last.date)) { PerformanceOutputPanel(text: last.outputTail, height: 160) }
                }
            }

            if !runs.isEmpty {
                Card("Previous runs", trailing: "\(runs.count)") {
                    ForEach(runs.prefix(10)) { record in
                        HStack {
                            Circle().fill(record.status == 0 ? Theme.success : Theme.danger).frame(width: 7, height: 7)
                            Text(Format.date(record.date)).font(Type.text(12)).foregroundStyle(Theme.ink)
                            Spacer()
                            Text("\(PerformanceTaskScreen.elapsed(record.duration)) · exit \(record.status)").font(Type.mono(11)).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var extra: some View {
        switch task {
        case .freeRAM:
            let m = monitor.latest.memory
            Card("Memory now · live") {
                LiveChart(series: [
                    .init(values: monitor.memoryBytesHistory, color: Theme.accent, label: "Used"),
                ], maxValue: Double(m.total), format: { Format.bytes(Int64($0)) }, height: 100)
                StackedBar(segments: PerformanceColors.memorySegments(m), total: Double(m.total))
                if let purge = store.purgeResult {
                    HStack(spacing: 18) {
                        KeyValueRow(key: "Available before", value: Format.bytes(purge.before))
                        KeyValueRow(key: "Available after", value: Format.bytes(purge.after))
                        KeyValueRow(key: "Change", value: (purge.delta >= 0 ? "+" : "−") + Format.bytes(abs(purge.delta)))
                    }
                }
            }
        case .thinSnapshots:
            NavRow(icon: "clock.arrow.circlepath", title: "Local snapshots", subtitle: "Snapshot list refreshes after thinning",
                   value: Format.count(store.snapshots.count), route: .performance(.snapshots))
                .onAppear { store.loadSnapshotsIfNeeded() }
        case .verifyDisk:
            let d = monitor.latest.disk
            TileGrid {
                StatTile(label: "Startup disk", value: Format.bytes(d.total), icon: "internaldrive")
                StatTile(label: "Used", value: Format.percent(d.usedFraction), detail: Format.bytes(d.used), tint: PerformanceColors.load(d.usedFraction))
                StatTile(label: "Read", value: Format.rate(d.readPerSec), history: monitor.diskReadHistory)
                StatTile(label: "Write", value: Format.rate(d.writePerSec), history: monitor.diskWriteHistory)
            }
        case .rebuildSpotlight:
            let indexers = monitor.processes.filter { $0.name.hasPrefix("mds") || $0.name.hasPrefix("mdworker") }
            Card("Spotlight processes · live", trailing: "\(indexers.count)") {
                if indexers.isEmpty {
                    Text("No mds/mdworker processes active").font(Type.text(12)).foregroundStyle(Theme.muted)
                }
                ForEach(indexers.sorted { $0.cpu > $1.cpu }.prefix(8)) { proc in
                    BarRow(label: "\(proc.name) · pid \(proc.pid)", value: proc.cpu, total: 100,
                           valueText: String(format: "%.1f%% · %@", proc.cpu, Format.bytes(proc.memory)))
                }
            }
        default:
            EmptyView()
        }
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return Format.duration(seconds)
    }
}

struct PerformanceHistoryScreen: View {
    @ObservedObject private var store = PerformanceStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var expanded: Set<UUID> = []
    @State private var filter: String = "all"

    var body: some View {
        let list = filter == "all" ? store.history : store.history.filter { $0.task == filter }
        ScreenScaffold("Maintenance History", subtitle: "Saved on this Mac · last 200 runs") {
            ConfirmButton(title: "Clear History", message: "Forget all recorded maintenance runs. Nothing on disk is changed.", kind: .ghost,
                          disabled: store.history.isEmpty) { store.clearHistory() }
        } content: {
            TileGrid {
                StatTile(label: "Runs", value: Format.count(store.history.count), icon: "list.number")
                StatTile(label: "Succeeded", value: Format.count(store.history.filter { $0.status == 0 }.count), tint: Theme.success, icon: "checkmark.circle")
                StatTile(label: "Failed", value: Format.count(store.history.filter { $0.status != 0 }.count), tint: Theme.danger, icon: "xmark.octagon")
                StatTile(label: "Time spent", value: PerformanceTaskScreen.elapsed(store.history.reduce(0) { $0 + $1.duration }), icon: "timer")
            }
            Picker("Task", selection: $filter) {
                Text("All tasks").tag("all")
                ForEach(PerformanceTask.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .frame(width: 280)
            if list.isEmpty {
                EmptyPanel(icon: "clock", title: "No runs yet", message: "Run a maintenance task and it will be recorded here.",
                           actionTitle: "Open Maintenance") { nav.push(.performance(.maintenance)) }
            } else {
                Card(nil, trailing: "\(list.count) runs") {
                    ForEach(list) { record in
                        let task = PerformanceTask(rawValue: record.task)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: task?.icon ?? "wrench").foregroundStyle(Theme.accent).frame(width: 20)
                                Text(task?.title ?? record.task).font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink)
                                RiskBadge(text: "exit \(record.status)", tint: record.status == 0 ? Theme.success : Theme.danger)
                                Spacer()
                                Text("\(Format.date(record.date)) · \(PerformanceTaskScreen.elapsed(record.duration))")
                                    .font(Type.mono(10)).foregroundStyle(Theme.muted)
                                Button(expanded.contains(record.id) ? "Hide" : "Output") {
                                    if expanded.contains(record.id) { expanded.remove(record.id) } else { expanded.insert(record.id) }
                                }
                                .buttonStyle(EditorialButtonStyle(kind: .inline))
                                if let task {
                                    Button("Open") { nav.push(.performance(task.route)) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                                }
                            }
                            if expanded.contains(record.id) {
                                PerformanceOutputPanel(text: record.outputTail, height: 140)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
}
